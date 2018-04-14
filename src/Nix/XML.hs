{-# LANGUAGE LambdaCase #-}

module Nix.XML where

import           Control.Arrow (first)
import           Data.Fix
import           Data.List (sortOn)
import           Data.Ord
import qualified Data.Text as Text
import           Nix.Atoms
import           Nix.AttrSet
import           Nix.Expr.Types
import           Nix.Value
import           Text.XML.Light

toXML :: Functor m => NValueNF m -> String
toXML = (.) ((++ "\n") .
             ("<?xml version='1.0' encoding='utf-8'?>\n" ++) .
             ppElement .
             (\e -> Element (unqual "expr") [] [Elem e] Nothing))
        $ cata
        $ \case
    NVConstant a -> case a of
        NInt n   -> mkElem "int" "value" (show n)
        NFloat f -> mkElem "float" "value" (show f)
        NBool b  -> mkElem "bool" "value" (if b then "true" else "false")
        NNull    -> Element (unqual "null") [] [] Nothing
        NUri u   -> mkElem "uri" "value" (Text.unpack u)

    NVStr t _ -> mkElem "string" "value" (Text.unpack t)
    NVList l  -> Element (unqual "list") [] (Elem <$> l) Nothing

    NVSet s -> Element (unqual "attrs") []
        (map (\(k, v) -> Elem (Element (unqual "attr")
                                      [Attr (unqual "name") (Text.unpack k)]
                                      [Elem v] Nothing))
             (sortOn fst $ undefined $ attrsetToList s)) Nothing

    NVClosure p _  -> Element (unqual "function") [] (paramsXML p) Nothing
    NVPath fp -> mkElem "path" "value" fp
    NVBuiltin name _ -> mkElem "function" "name" name

mkElem :: String -> String -> String -> Element
mkElem n a v = Element (unqual n) [Attr (unqual a) v] [] Nothing

paramsXML :: Params r -> [Content]
paramsXML (Param name) =
    [Elem $ mkElem "varpat" "name" (Text.unpack name)]
paramsXML (ParamSet s b mname) =
    [Elem $ Element (unqual "attrspat") (battr ++ nattr) (paramSetXML s) Nothing]
  where
    battr = [ Attr (unqual "ellipsis") "1" | b ]
    nattr = maybe [] ((:[]) . Attr (unqual "name") . Text.unpack) mname

paramSetXML :: ParamSet r -> [Content]
paramSetXML = map (\(k,_) -> Elem $ mkElem "attr" "name" (Text.unpack k))
