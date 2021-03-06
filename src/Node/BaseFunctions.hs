module Node.BaseFunctions where

import Control.Exception

undead :: IO a -> IO b -> IO b
undead fin f = finally f (fin >> undead fin f)
