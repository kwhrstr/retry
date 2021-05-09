module Main
    ( main
    ) where


-------------------------------------------------------------------------------
import           Test.Tasty
-------------------------------------------------------------------------------
import qualified Tests.UnliftIO.Retry
-------------------------------------------------------------------------------



main :: IO ()
main = defaultMain tests


-------------------------------------------------------------------------------
tests :: TestTree
tests = testGroup "retry"
  [ Tests.UnliftIO.Retry.tests
  ]
