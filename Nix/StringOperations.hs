-- | Functions for manipulating nix strings.
module Nix.StringOperations where

import Nix.Expr
import           Data.List (intercalate)
import           Data.Monoid ((<>))
import qualified Data.Text as T
import           Prelude hiding (elem)
import           Data.Tuple (swap)


-- | Merge adjacent 'Plain' values with 'mappend'.
mergePlain :: [Antiquoted r] -> [Antiquoted r]
mergePlain [] = []
mergePlain (Plain a: Plain b: xs) = mergePlain (Plain (a <> b) : xs)
mergePlain (x:xs) = x : mergePlain xs

-- | Remove 'Plain' values equal to 'mempty', as they don't have any
-- informational content.
removePlainEmpty :: [Antiquoted r] -> [Antiquoted r]
removePlainEmpty = filter f where
  f (Plain x) = x /= mempty
  f _ = True

-- | Split a stream representing a string with antiquotes on line breaks.
splitLines :: [Antiquoted r] -> [[Antiquoted r]]
splitLines = uncurry (flip (:)) . go where
  go (Plain t : xs) = (Plain l :) <$> foldr f (go xs) ls where
    (l : ls) = T.split (=='\n') t
    f prefix (finished, current) = ((Plain prefix : current) : finished, [])
  go (Antiquoted a : xs) = (Antiquoted a :) <$> go xs
  go [] = ([],[])

-- | Join a stream of strings containing antiquotes again. This is the inverse
-- of 'splitLines'.
unsplitLines :: [[Antiquoted r]] -> [Antiquoted r]
unsplitLines = intercalate [Plain "\n"]

-- | Form an indented string by stripping spaces equal to the minimal indent.
stripIndent :: [Antiquoted r] -> NString r
stripIndent [] = Indented []
stripIndent xs =
  Indented . removePlainEmpty . mergePlain . unsplitLines $ ls'
  where
    ls = stripEmptyOpening $ splitLines xs
    ls' = map (dropSpaces minIndent) ls

    minIndent = case stripEmptyLines ls of
      [] -> 0
      nonEmptyLs -> minimum $ map (countSpaces . mergePlain) nonEmptyLs

    stripEmptyLines = filter $ \case
      [Plain t] -> not $ T.null $ T.strip t
      _ -> True

    stripEmptyOpening ([Plain t]:ts) | T.null (T.strip t) = ts
    stripEmptyOpening ts = ts

    countSpaces (Antiquoted _:_) = 0
    countSpaces (Plain t : _) = T.length . T.takeWhile (== ' ') $ t
    countSpaces [] = 0

    dropSpaces 0 x = x
    dropSpaces n (Plain t : cs) = Plain (T.drop n t) : cs
    dropSpaces _ _ = error "stripIndent: impossible"

escapeCodes :: [(Char, Char)]
escapeCodes =
  [ ('\n', 'n' )
  , ('\r', 'r' )
  , ('\t', 't' )
  , ('\\', '\\')
  , ('$' , '$' )
  , ('"', '"')
  ]

fromEscapeCode :: Char -> Maybe Char
fromEscapeCode = (`lookup` map swap escapeCodes)

toEscapeCode :: Char -> Maybe Char
toEscapeCode = (`lookup` escapeCodes)
