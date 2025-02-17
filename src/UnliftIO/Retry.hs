{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE MagicHash             #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE UnboxedTuples         #-}
{-# LANGUAGE ViewPatterns          #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Retry
-- Copyright   :  Ozgun Ataman <ozgun.ataman@soostone.com>
-- License     :  BSD3
--
-- Maintainer  :  Ozgun Ataman
-- Stability   :  provisional
--
-- This module exposes combinators that can wrap arbitrary monadic
-- actions. They run the action and potentially retry running it with
-- some configurable delay for a configurable number of times.
--
-- The express purpose of this library is to make it easier to work
-- with IO and especially network IO actions that often experience
-- temporary failure that warrant retrying of the original action. For
-- example, a database query may time out for a while, in which case
-- we should delay a bit and retry the query.
----------------------------------------------------------------------------


module UnliftIO.Retry
    (
      -- * Types and Operations
      RetryPolicyM (..)
    , RetryPolicy
    , retryPolicy
    , retryPolicyDefault
    , natTransformRetryPolicy
    , RetryAction (..)
    , toRetryAction
    , RetryStatus (..)
    , defaultRetryStatus
    , applyPolicy
    , applyAndDelay


    -- ** Lenses for 'RetryStatus'
    , rsIterNumberL
    , rsCumulativeDelayL
    , rsPreviousDelayL

    -- * Applying Retry Policies
    , retrying
    , retryingDynamic
    , recovering
    , recoveringDynamic
    , stepping
    , recoverAll
    , skipAsyncExceptions
    , logRetries
    , defaultLogMsg

    -- * Retry Policies
    , constantDelay
    , exponentialBackoff
    , fullJitterBackoff
    , fibonacciBackoff
    , limitRetries

    -- * Policy Transformers
    , limitRetriesByDelay
    , limitRetriesByCumulativeDelay
    , capDelay

    -- * Development Helpers
    , simulatePolicy
    , simulatePolicyPP
    ) where

-------------------------------------------------------------------------------
import           Control.Applicative

import           Control.Monad
import           UnliftIO (MonadUnliftIO, MonadIO, liftIO)
import           UnliftIO.Exception(Exception, AsyncExceptionWrapper, SomeException, SomeAsyncException, Handler(..), mask, try, fromException, throwIO)
import           UnliftIO.Concurrent (threadDelay)
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Maybe
import           Control.Monad.Trans.State
import           Data.List (foldl')
import           Data.Maybe
import           GHC.Generics
import           GHC.Prim
import           GHC.Types (Int(I#))
import           System.Random
import           Data.Semigroup
import           Prelude
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
-- | A 'RetryPolicyM' is a function that takes an 'RetryStatus' and
-- possibly returns a delay in microseconds.  Iteration numbers start
-- at zero and increase by one on each retry.  A *Nothing* return value from
-- the function implies we have reached the retry limit.
--
-- Please note that 'RetryPolicyM' is a 'Monoid'. You can collapse
-- multiple strategies into one using 'mappend' or '<>'. The semantics
-- of this combination are as follows:
--
-- 1. If either policy returns 'Nothing', the combined policy returns
-- 'Nothing'. This can be used to @inhibit@ after a number of retries,
-- for example.
--
-- 2. If both policies return a delay, the larger delay will be used.
-- This is quite natural when combining multiple policies to achieve a
-- certain effect.
--
-- Example:
--
-- One can easily define an exponential backoff policy with a limited
-- number of retries:
--
-- >> limitedBackoff = exponentialBackoff 50000 <> limitRetries 5
--
-- Naturally, 'mempty' will retry immediately (delay 0) for an
-- unlimited number of retries, forming the identity for the 'Monoid'.
--
-- The default retry policy 'retryPolicyDefault' implements a constant 50ms delay, up to 5 times:
--
-- >> retryPolicyDefault = constantDelay 50000 <> limitRetries 5
--
-- For anything more complex, just define your own 'RetryPolicyM':
--
-- >> myPolicy = retryPolicy $ \ rs -> if rsIterNumber rs > 10 then Just 1000 else Just 10000
--
-- Since 0.7.
newtype RetryPolicyM m = RetryPolicyM { getRetryPolicyM :: RetryStatus -> m (Maybe Int) }


-- | Simplified 'RetryPolicyM' without any use of the monadic context in
-- determining policy. Mostly maintains backwards compatitibility with
-- type signatures pre-0.7.
type RetryPolicy = forall m . Monad m => RetryPolicyM m

-- | Default retry policy
retryPolicyDefault :: (Monad m) => RetryPolicyM m
retryPolicyDefault = constantDelay 50000 <> limitRetries 5


-- Base 4.9.0 adds a Data.Semigroup module. This has fewer
-- dependencies than the semigroups package, so we're using base's
-- only if its available.

instance Monad m => Semigroup (RetryPolicyM m) where
  (RetryPolicyM a) <> (RetryPolicyM b) = RetryPolicyM $ \ n -> runMaybeT $ do
    a' <- MaybeT $ a n
    b' <- MaybeT $ b n
    return $! max a' b'


instance Monad m => Monoid (RetryPolicyM m) where
    mempty = retryPolicy $ const (Just 0)
    mappend = (<>)


-------------------------------------------------------------------------------
-- | Applies a natural transformation to a policy to run a RetryPolicy
-- meant for the monad @m@ in the monad @n@ provided a transformation
-- from @m@ to @n@ is available. A common case is if you have a pure
-- policy, @RetryPolicyM Identity@ and want to use it to govern an
-- @IO@ computation you could write:
--
-- @
--   purePolicyInIO :: RetryPolicyM Identity -> RetryPolicyM IO
--   purePolicyInIO = natTransformRetryPolicy (pure . runIdentity)
-- @
natTransformRetryPolicy :: (forall a. m a -> n a) -> RetryPolicyM m -> RetryPolicyM n
natTransformRetryPolicy f (RetryPolicyM p) = RetryPolicyM $ \stat -> f (p stat)


-- | Modify the delay of a RetryPolicy.
-- Does not change whether or not a retry is performed.
modifyRetryPolicyDelay :: Functor m => (Int -> Int) -> RetryPolicyM m -> RetryPolicyM m
modifyRetryPolicyDelay f (RetryPolicyM p) = RetryPolicyM (fmap (fmap f) . p)


-------------------------------------------------------------------------------
-- | How to handle a failed action.
data RetryAction
    = DontRetry
    -- ^ Don't retry (regardless of what the 'RetryPolicy' says).
    | ConsultPolicy
    -- ^ Retry if the 'RetryPolicy' says so, with the delay specified by the policy.
    | ConsultPolicyOverrideDelay Int
    -- ^ Retry if the 'RetryPolicy' says so, but override the policy's delay (number of microseconds).
      deriving (Read, Show, Eq, Generic)


-- | Convert a boolean answer to the question "Should we retry?" into
-- a 'RetryAction'.
toRetryAction :: Bool -> RetryAction
toRetryAction False = DontRetry
toRetryAction True = ConsultPolicy

-------------------------------------------------------------------------------
-- | Datatype with stats about retries made thus far. The constructor
-- is deliberately not exported to make additional fields easier to
-- add in a backward-compatible manner. To read or modify fields in
-- RetryStatus, use the accessors or lenses below. Note that if you
-- don't want to use lenses, the exported field names can be used for
-- updates:
--
-- >> retryStatus { rsIterNumber = newIterNumber }
-- >> retryStatus & rsIterNumberL .~ newIterNumber
data RetryStatus = RetryStatus
    { rsIterNumber      :: !Int -- ^ Iteration number, where 0 is the first try
    , rsCumulativeDelay :: !Int -- ^ Delay incurred so far from retries in microseconds
    , rsPreviousDelay   :: !(Maybe Int) -- ^ Latest attempt's delay. Will always be Nothing on first run.
    } deriving (Read, Show, Eq, Generic)


-------------------------------------------------------------------------------
-- | Initial, default retry status. Exported mostly to allow user code
-- to test their handlers and retry policies. Use fields or lenses to update.
defaultRetryStatus :: RetryStatus
defaultRetryStatus = RetryStatus 0 0 Nothing

-------------------------------------------------------------------------------
rsIterNumberL :: Lens' RetryStatus Int
rsIterNumberL = lens rsIterNumber (\rs x -> rs { rsIterNumber = x })
{-# INLINE rsIterNumberL #-}


-------------------------------------------------------------------------------
rsCumulativeDelayL :: Lens' RetryStatus Int
rsCumulativeDelayL = lens rsCumulativeDelay (\rs x -> rs { rsCumulativeDelay = x })
{-# INLINE rsCumulativeDelayL #-}


-------------------------------------------------------------------------------
rsPreviousDelayL :: Lens' RetryStatus (Maybe Int)
rsPreviousDelayL = lens rsPreviousDelay (\rs x -> rs { rsPreviousDelay = x })
{-# INLINE rsPreviousDelayL #-}



-------------------------------------------------------------------------------
-- | Apply policy on status to see what the decision would be.
-- 'Nothing' implies no retry, 'Just' returns updated status.
applyPolicy
    :: Monad m
    => RetryPolicyM m
    -> RetryStatus
    -> m (Maybe RetryStatus)
applyPolicy (RetryPolicyM policy) s = do
    res <- policy s
    case res of
      Just delay -> return $! Just $! RetryStatus
          { rsIterNumber = rsIterNumber s + 1
          , rsCumulativeDelay = rsCumulativeDelay s `boundedPlus` delay
          , rsPreviousDelay = Just delay }
      Nothing -> return Nothing


-------------------------------------------------------------------------------
-- | Apply policy and delay by its amount if it results in a retry.
-- Return updated status.
applyAndDelay
    :: MonadIO m
    => RetryPolicyM m
    -> RetryStatus
    -> m (Maybe RetryStatus)
applyAndDelay policy s = do
    chk <- applyPolicy policy s
    case chk of
      Just rs -> do
        case rsPreviousDelay rs of
          Nothing -> return ()
          Just delay -> liftIO $ threadDelay delay
        return (Just rs)
      Nothing -> return Nothing



-------------------------------------------------------------------------------
-- | Helper for making simplified policies that don't use the monadic
-- context.
retryPolicy :: (Monad m) => (RetryStatus -> Maybe Int) -> RetryPolicyM m
retryPolicy f = RetryPolicyM $ \ s -> return (f s)


-------------------------------------------------------------------------------
-- | Retry immediately, but only up to @n@ times.
limitRetries
    :: Int
    -- ^ Maximum number of retries.
    -> RetryPolicy
limitRetries i = retryPolicy $ \ RetryStatus { rsIterNumber = n} -> if n >= i then Nothing else Just 0


-------------------------------------------------------------------------------
-- | Add an upperbound to a policy such that once the given time-delay
-- amount *per try* has been reached or exceeded, the policy will stop
-- retrying and fail. If you need to stop retrying once *cumulative*
-- delay reaches a time-delay amount, use
-- 'limitRetriesByCumulativeDelay'
limitRetriesByDelay
    :: Monad m
    => Int
    -- ^ Time-delay limit in microseconds.
    -> RetryPolicyM m
    -> RetryPolicyM m
limitRetriesByDelay i p = RetryPolicyM (fmap (>>= limit) . getRetryPolicyM p)
  where
    limit delay = if delay >= i then Nothing else Just delay


-------------------------------------------------------------------------------
-- | Add an upperbound to a policy such that once the cumulative delay
-- over all retries has reached or exceeded the given limit, the
-- policy will stop retrying and fail.
limitRetriesByCumulativeDelay
    :: Monad m
    => Int
    -- ^ Time-delay limit in microseconds.
    -> RetryPolicyM m
    -> RetryPolicyM m
limitRetriesByCumulativeDelay cumulativeLimit p = RetryPolicyM $ \ stat ->
  (>>= limit stat) <$> getRetryPolicyM p stat
  where
    limit status curDelay
      | rsCumulativeDelay status `boundedPlus` curDelay > cumulativeLimit = Nothing
      | otherwise = Just curDelay


-------------------------------------------------------------------------------
-- | Implement a constant delay with unlimited retries.
constantDelay
    :: (Monad m)
    => Int
    -- ^ Base delay in microseconds
    -> RetryPolicyM m
constantDelay delay = retryPolicy (const (Just delay))


-------------------------------------------------------------------------------
-- | Grow delay exponentially each iteration.  Each delay will
-- increase by a factor of two.
exponentialBackoff
    :: (Monad m)
    => Int
    -- ^ Base delay in microseconds
    -> RetryPolicyM m
exponentialBackoff base = retryPolicy $ \ RetryStatus { rsIterNumber = n } ->
  Just $! base `boundedMult` boundedPow 2 n

-------------------------------------------------------------------------------
-- | FullJitter exponential backoff as explained in AWS Architecture
-- Blog article.
--
-- @http:\/\/www.awsarchitectureblog.com\/2015\/03\/backoff.html@
--
-- temp = min(cap, base * 2 ** attempt)
--
-- sleep = temp \/ 2 + random_between(0, temp \/ 2)
fullJitterBackoff
    :: (MonadIO m)
    => Int
    -- ^ Base delay in microseconds
    -> RetryPolicyM m
fullJitterBackoff base = RetryPolicyM $ \ RetryStatus { rsIterNumber = n } -> do
  let d = (base `boundedMult` boundedPow 2 n) `div` 2
  rand <- liftIO $ randomRIO (0, d)
  return $! Just $! d `boundedPlus` rand


-------------------------------------------------------------------------------
-- | Implement Fibonacci backoff.
fibonacciBackoff
    :: (Monad m)
    => Int
    -- ^ Base delay in microseconds
    -> RetryPolicyM m
fibonacciBackoff base = retryPolicy $ \RetryStatus { rsIterNumber = n } ->
  Just $ fib (n + 1) (0, base)
    where
      fib 0 (a, _) = a
      fib !m (!a, !b) = fib (m-1) (b, a `boundedPlus` b)


-------------------------------------------------------------------------------
-- | Set a time-upperbound for any delays that may be directed by the
-- given policy.  This function does not terminate the retrying.  The policy
-- `capDelay maxDelay (exponentialBackoff n)` will never stop retrying.  It
-- will reach a state where it retries forever with a delay of `maxDelay`
-- between each one.  To get termination you need to use one of the
-- 'limitRetries' function variants.
capDelay
    :: Monad m
    => Int
    -- ^ A maximum delay in microseconds
    -> RetryPolicyM m
    -> RetryPolicyM m
capDelay limit p = RetryPolicyM (fmap (fmap (min limit)) . getRetryPolicyM p)


-------------------------------------------------------------------------------
-- | Retry combinator for actions that don't raise exceptions, but
-- signal in their type the outcome has failed. Examples are the
-- 'Maybe', 'Either' and 'EitherT' monads.
--
-- Let's write a function that always fails and watch this combinator
-- retry it 5 additional times following the initial run:
--
-- >>> import Data.Maybe
-- >>> let f _ = putStrLn "Running action" >> return Nothing
-- >>> retrying retryPolicyDefault (const $ return . isNothing) f
-- Running action
-- Running action
-- Running action
-- Running action
-- Running action
-- Running action
-- Nothing
--
-- Note how the latest failing result is returned after all retries
-- have been exhausted.
retrying  :: MonadIO m
          => RetryPolicyM m
          -> (RetryStatus -> b -> m Bool)
          -- ^ An action to check whether the result should be retried.
          -- If True, we delay and retry the operation.
          -> (RetryStatus -> m b)
          -- ^ Action to run
          -> m b
retrying policy chk = retryingDynamic policy (\rs -> fmap toRetryAction . chk rs)


-------------------------------------------------------------------------------
-- | Same as 'retrying', but with the ability to override
-- the delay of the retry policy based on information
-- obtained after initiation.
--
-- For example, if the action to run is a HTTP request that
-- turns out to fail with a status code 429 ("too many requests"),
-- the response may contain a "Retry-After" HTTP header which
-- specifies the number of seconds
-- the client should wait until performing the next request.
-- This function allows overriding the delay calculated by the given
-- retry policy with the delay extracted from this header value.
--
-- In other words, given an arbitrary 'RetryPolicyM' @rp@, the
-- following invocation will always delay by 1000 microseconds:
--
-- > retryingDynamic rp (\_ _ -> return $ ConsultPolicyOverrideDelay 1000) f
--
-- Note that a 'RetryPolicy's decision to /not/ perform a retry
-- cannot be overridden. Ie. /when/ to /stop/ retrying is always decided
-- by the retry policy, regardless of the returned 'RetryAction' value.
retryingDynamic
    :: MonadIO m
    => RetryPolicyM m
    -> (RetryStatus -> b -> m RetryAction)
    -- ^ An action to check whether the result should be retried.
    -- The returned 'RetryAction' determines how/if a retry is performed.
    -- See documentation on 'RetryAction'.
    -> (RetryStatus -> m b)
    -- ^ Action to run
    -> m b
retryingDynamic policy chk f = go defaultRetryStatus
  where
    go s = do
        res <- f s
        let consultPolicy policy' = do
              rs <- applyAndDelay policy' s
              case rs of
                Nothing -> return res
                Just rs' -> go $! rs'
        chk' <- chk s res
        case chk' of
          DontRetry -> return res
          ConsultPolicy -> consultPolicy policy
          ConsultPolicyOverrideDelay delay ->
            consultPolicy $ modifyRetryPolicyDelay (const delay) policy


-------------------------------------------------------------------------------
-- | Retry ALL exceptions that may be raised. To be used with caution;
-- this matches the exception on 'SomeException'. Note that this
-- handler explicitly does not handle 'AsyncException' nor
-- 'SomeAsyncException' (for versions of base >= 4.7). It is not a
-- good idea to catch async exceptions as it can result in hanging
-- threads and programs. Note that if you just throw an exception to
-- this thread that does not descend from SomeException, recoverAll
-- will not catch it.
--
-- See how the action below is run once and retried 5 more times
-- before finally failing for good:
--
-- >>> let f _ = putStrLn "Running action" >> error "this is an error"
-- >>> recoverAll retryPolicyDefault f
-- Running action
-- Running action
-- Running action
-- Running action
-- Running action
-- Running action
-- *** Exception: this is an error
recoverAll
         :: (MonadUnliftIO m)
         => RetryPolicyM m
         -> (RetryStatus -> m a)
         -> m a
recoverAll set = recovering set handlers
    where
      handlers = skipAsyncExceptions ++ [h]
      h _ = Handler $ \ (_ :: SomeException) -> return True


-------------------------------------------------------------------------------
-- | List of pre-made handlers that will skip retries on
-- 'AsyncException' and 'SomeAsyncException'. Append your handlers to
-- this list as a convenient way to make sure you're not catching
-- async exceptions like user interrupt.
skipAsyncExceptions
    :: ( MonadIO m
       )
    => [RetryStatus -> Handler m Bool]
skipAsyncExceptions = handlers
  where
    asyncH _ = Handler $ \ (_ :: AsyncExceptionWrapper) -> return False

    someAsyncH _ = Handler $ \(_ :: SomeAsyncException) -> return False
    handlers = [asyncH, someAsyncH]





-------------------------------------------------------------------------------
-- | Run an action and recover from a raised exception by potentially
-- retrying the action a number of times. Note that if you're going to
-- use a handler for 'SomeException', you should add explicit cases
-- *earlier* in the list of handlers to reject 'AsyncException' and
-- 'SomeAsyncException', as catching these can cause thread and
-- program hangs. 'recoverAll' already does this for you so if you
-- just plan on catching 'SomeException', you may as well ues
-- 'recoverAll'
recovering
    :: (MonadUnliftIO m)
    => RetryPolicyM m
    -- ^ Just use 'retryPolicyDefault' for default settings
    -> [RetryStatus -> Handler m Bool]
    -- ^ Should a given exception be retried? Action will be
    -- retried if this returns True *and* the policy allows it.
    -- This action will be consulted first even if the policy
    -- later blocks it.
    -> (RetryStatus -> m a)
    -- ^ Action to perform
    -> m a
recovering policy hs = recoveringDynamic policy hs'
  where
    hs' = map (fmap' toRetryAction .) hs
    fmap' f (Handler h) = Handler (fmap f . h)

-- | The difference between this and 'recovering' is the same as
--  the difference between 'retryingDynamic' and 'retrying'.
recoveringDynamic
    :: (MonadUnliftIO m)
    => RetryPolicyM m
    -- ^ Just use 'retryPolicyDefault' for default settings
    -> [RetryStatus -> Handler m RetryAction]
    -- ^ Should a given exception be retried? Action will be
    -- retried if this returns either 'ConsultPolicy' or
    -- 'ConsultPolicyOverrideDelay' *and* the policy allows it.
    -- This action will be consulted first even if the policy
    -- later blocks it.
    -> (RetryStatus -> m a)
    -- ^ Action to perform
    -> m a
recoveringDynamic policy hs f = mask $ \restore -> go restore defaultRetryStatus
    where
      go restore = loop
        where
          loop s = do
            r <- try $ restore (f s)
            case r of
              Right x -> return x
              Left e -> recover (e :: SomeException) hs
            where
              recover e [] = throwIO e
              recover e ((($ s) -> Handler h) : hs')
                | Just e' <- fromException e = do
                    let consultPolicy policy' = do
                          rs <- applyAndDelay policy' s
                          case rs of
                            Just rs' -> loop $! rs'
                            Nothing -> throwIO e'
                    chk <- h e'
                    case chk of
                      DontRetry -> throwIO e'
                      ConsultPolicy -> consultPolicy policy
                      ConsultPolicyOverrideDelay delay ->
                        consultPolicy $ modifyRetryPolicyDelay (const delay) policy
                | otherwise = recover e hs'



-------------------------------------------------------------------------------
-- | A version of 'recovering' that tries to run the action only a
-- single time. The control will return immediately upon both success
-- and failure. Useful for implementing retry logic in distributed
-- queues and similar external-interfacing systems.
stepping
    :: (MonadUnliftIO m)
    => RetryPolicyM m
    -- ^ Just use 'retryPolicyDefault' for default settings
    -> [RetryStatus -> Handler m Bool]
    -- ^ Should a given exception be retried? Action will be
    -- retried if this returns True *and* the policy allows it.
    -- This action will be consulted first even if the policy
    -- later blocks it.
    -> (RetryStatus -> m ())
    -- ^ Action to run with updated status upon failure.
    -> (RetryStatus -> m a)
    -- ^ Main action to perform with current status.
    -> RetryStatus
    -- ^ Current status of this step
    -> m (Maybe a)
stepping policy hs schedule f s = do
    r <- try $ f s
    case r of
      Right x -> return $ Just x
      Left e -> recover (e :: SomeException) hs
    where
      recover e [] = throwIO e
      recover e ((($ s) -> Handler h) : hs')
        | Just e' <- fromException e = do
            h e' >>= \chk -> unless chk . throwIO $ e'            
            res <- applyPolicy policy s
            case res of
              Just rs -> do
                schedule $! rs
                return Nothing
              Nothing -> throwIO e'
        | otherwise = recover e hs'


-------------------------------------------------------------------------------
-- | Helper function for constructing handler functions of the form required
-- by 'recovering'.
logRetries
    :: ( Monad m
       , Exception e)
    => (e -> m Bool)
    -- ^ Test for whether action is to be retried
    -> (Bool -> e -> RetryStatus -> m ())
    -- ^ How to report the generated warning message. Boolean is
    -- whether it's being retried or crashed.
    -> RetryStatus
    -- ^ Retry number
    -> Handler m Bool
logRetries test reporter status = Handler $ \ err -> do
    result <- test err
    reporter result err status
    return result

-- | For use with 'logRetries'.
defaultLogMsg :: (Exception e) => Bool -> e -> RetryStatus -> String
defaultLogMsg shouldRetry err status =
    "[retry:" <> iter <> "] Encountered " <> show err <> ". " <> nextMsg
  where
    iter = show $ rsIterNumber status
    nextMsg = if shouldRetry then "Retrying." else "Crashing."


-------------------------------------------------------------------------------
-- | Run given policy up to N iterations and gather results. In the
-- pair, the @Int@ is the iteration number and the @Maybe Int@ is the
-- delay in microseconds.
simulatePolicy :: Monad m => Int -> RetryPolicyM m -> m [(Int, Maybe Int)]
simulatePolicy n (RetryPolicyM f) = flip evalStateT defaultRetryStatus $ forM [0..n] $ \i -> do
  stat <- get
  delay <- lift (f stat)
  put $! stat
    { rsIterNumber = i + 1
    , rsCumulativeDelay = rsCumulativeDelay stat `boundedPlus` fromMaybe 0 delay
    , rsPreviousDelay = delay
    }
  return (i, delay)


-------------------------------------------------------------------------------
-- | Run given policy up to N iterations and pretty print results on
-- the console.
simulatePolicyPP :: Int -> RetryPolicyM IO -> IO ()
simulatePolicyPP n p = do
    ps <- simulatePolicy n p
    forM_ ps $ \ (iterNo, res) -> putStrLn $
      show iterNo <> ": " <> maybe "Inhibit" ppTime res
    putStrLn $ "Total cumulative delay would be: " <>
      ppTime (boundedSum $ mapMaybe snd ps)


-------------------------------------------------------------------------------
ppTime :: (Integral a, Show a) => a -> String
ppTime n | n < 1000 = show n <> "us"
         | n < 1000000 = show ((fromIntegral n / 1000) :: Double) <> "ms"
         | otherwise = show ((fromIntegral n / 1000) :: Double) <> "ms"

-------------------------------------------------------------------------------
-- Bounded arithmetic
-------------------------------------------------------------------------------

-- | Same as '+' on 'Int' but it maxes out at @'maxBound' :: 'Int'@ or
-- @'minBound' :: 'Int'@ rather than rolling over
boundedPlus :: Int -> Int -> Int
boundedPlus i@(I# i#) j@(I# j#) = case addIntC# i# j# of
  (# k#, 0# #) -> I# k#
  (# _, _ #)
    | maxBy abs i j < 0 -> minBound
    | otherwise -> maxBound
  where
    maxBy f a b = if f a >= f b then a else b

-- | Same as '*' on 'Int' but it maxes out at @'maxBound' :: 'Int'@ or
-- @'minBound' :: 'Int'@ rather than rolling over
boundedMult :: Int -> Int -> Int
boundedMult i@(I# i#) j@(I# j#) = case mulIntMayOflo# i# j# of
  0# -> I# (i# *# j#)
  _ | signum i * signum j < 0 -> minBound
    | otherwise -> maxBound

-- | Same as 'sum' on 'Int' but it maxes out at @'maxBound' :: 'Int'@ or
-- @'minBound' :: 'Int'@ rather than rolling over
boundedSum :: [Int] -> Int
boundedSum = foldl' boundedPlus 0

-- | Same as '^' on 'Int' but it maxes out at @'maxBound' :: 'Int'@ or
-- @'MinBound' :: 'Int'@ rather than rolling over
boundedPow :: Int -> Int -> Int
boundedPow x0 y0
  | y0 < 0 = error "Negative exponent"
  | y0 == 0 = 1
  | otherwise = f x0 y0
  where
    f x y
      | even y = f (x `boundedMult` x) (y `quot` 2)
      | y == 1 = x
      | otherwise = g (x `boundedMult` x) ((y - 1) `quot` 2) x
    g x y z
      | even y = g (x `boundedMult` x) (y `quot` 2) z
      | y == 1 = x `boundedMult` z
      | otherwise = g (x `boundedMult` x) ((y - 1) `quot` 2) (x `boundedMult` z)

-------------------------------------------------------------------------------
-- Lens machinery
-------------------------------------------------------------------------------
-- Unexported type aliases to clean up the documentation
type Lens s t a b = forall f. Functor f => (a -> f b) -> s -> f t

type Lens' s a = Lens s s a a


-------------------------------------------------------------------------------
lens :: (s -> a) -> (s -> b -> t) -> Lens s t a b
lens sa sbt afb s = sbt s <$> afb (sa s)
{-# INLINE lens #-}


                              ------------------
                              -- Simple Tests --
                              ------------------



-- data TestException = TestException deriving (Show, Typeable)
-- data AnotherException = AnotherException deriving (Show, Typeable)

-- instance Exception TestException
-- instance Exception AnotherException


-- test = retrying retryPolicyDefault [h1,h2] f
--     where
--       f = putStrLn "Running action" >> throwIO AnotherException
--       h1 = Handler $ \ (e :: TestException) -> return False
--       h2 = Handler $ \ (e :: AnotherException) -> return True
