{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -fno-warn-name-shadowing #-}

module Nix.Eval where

import           Control.Applicative
import           Control.Arrow (first)
import           Control.Monad
import           Control.Monad.Fix
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Reader
import           Data.Align.Key
import           Data.Fix
import           Data.Functor.Compose
import           Data.List (intercalate, partition, foldl')
import           Data.Maybe (fromMaybe, catMaybes)
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.These
import           Data.Traversable (for)
import           Nix.Atoms
import           Nix.AttrSet
import           Nix.Expr
import           Nix.Scope
import           Nix.Stack
import           Nix.StringOperations (runAntiquoted)
import           Nix.Thunk
import           Nix.Utils

class (Show v, Monoid (MText v), Monad m) => MonadEval v m | v -> m where
    freeVariable :: Text -> m v

    evalCurPos      :: m v
    evalConstant    :: NAtom -> m v
    evalString      :: MText v -> m v
    evalLiteralPath :: FilePath -> m v
    evalEnvPath     :: FilePath -> m v
    evalUnary       :: NUnaryOp -> v -> m v
    evalBinary      :: NBinaryOp -> v -> m v -> m v
    -- ^ The second argument is an action because operators such as boolean &&
    -- and || may not evaluate the second argument.
    evalWith        :: m v -> m v -> m v
    evalIf          :: v -> m v -> m v -> m v
    evalAssert      :: v -> m v -> m v
    evalApp         :: v -> m v -> m v
    evalAbs         :: Params () -> (m v -> m v) -> m v

    evalError :: String -> m a

    type MText v :: *

    wrapMText   :: Text -> m (MText v)
    unwrapMText :: MText v -> m Text

    embedMText   :: MText v -> m v
    projectMText :: v -> m (Maybe (Maybe (MText v)))

type MonadNixEval e v t m =
    (MonadEval v m, Scoped e t m, MonadThunk v t m, MonadFix m,
     ConvertValue v Bool,
     ConvertValue v [t],
     ConvertValue v (AttrSet t), Show t, AttrSetEmbeds t)

-- | Evaluate an nix expression, with a given NThunkSet as environment
evalExpr :: MonadNixEval e v t m => NExpr -> m v
evalExpr = cata eval

eval :: forall e v t m. MonadNixEval e v t m => NExprF (m v) -> m v

eval (NSym "__curPos") = evalCurPos

eval (NSym var) = lookupVar var >>= \case
    Nothing -> freeVariable var
    Just v  -> force v pure

eval (NConstant x)          = evalConstant x
eval (NStr str)             = evalString =<< assembleString str
eval (NLiteralPath p)       = evalLiteralPath p
eval (NEnvPath p)           = evalEnvPath p
eval (NUnary op arg)        = evalUnary op =<< arg

eval (NBinary NApp fun arg) = do
    traceM "NApp"
    scope <- currentScopes @_ @t
    evalApp ?? withScopes scope arg =<< fun

eval (NBinary op larg rarg) = join $ evalBinary op <$> larg <*> pure rarg

eval (NSelect aset attr alt) = do
    traceM "NSelect"
    mres <- evalSelect aset attr
    case mres of
        Right v -> pure v
        Left (s, ks) -> fromMaybe err alt
          where
            err = evalError @v $ "Could not look up attribute "
                ++ intercalate "." (map Text.unpack ks)
                ++ " in " ++ show @v s

eval (NHasAttr aset attr) = do
    traceM "NHasAttr"
    ofVal . either (const False) (const True)
        <$> evalSelect aset attr

eval (NList l) = do
    traceM "NList"
    scope <- currentScopes
    ofVal <$> for l (thunk . withScopes @t scope)

eval (NSet binds) = do
    traceM "NSet..1"
    s <- evalBinds True False binds
    traceM $ "NSet..2: s = " ++ show s
    return $ ofVal s

eval (NRecSet binds) = do
    traceM "NRecSet..1"
    s <- evalBinds True True binds
    traceM $ "NRecSet..2: s = " ++ show s
    return $ ofVal s

eval (NLet binds e) = do
    traceM "Let..1"
    s <- evalBinds True True binds
    traceM $ "Let..2: s = " ++ show s
    pushScope s e

eval (NIf cond t f) = cond >>= \v -> evalIf v t f

eval (NWith scope body) = evalWith scope body

eval (NAssert cond body) = cond >>= \v -> evalAssert v body

eval (NAbs params body) = do
    -- It is the environment at the definition site, not the call site, that
    -- needs to be used when evaluating the body and default arguments, hence
    -- we defer here so the present scope is restored when the parameters and
    -- body are forced during application.
    traceM "NAbs"
    scope <- currentScopes @_ @t
    traceM $ "Creating lambda abstraction in scope: " ++ show scope
    evalAbs (void params) $ \arg ->
        withScopes @t scope $ do
            args <- buildArgument params arg
            pushScope args body

attrSetAlter :: forall e v t m. MonadNixEval e v t m
             => [Text]
             -> AttrSet (m v)
             -> m v
             -> m (AttrSet (m v))
attrSetAlter [] _ _ = evalError @v "invalid selector with no components"
attrSetAlter _ _ _ = undefined
{-
attrSetAlter (p:ps) m val = case M.lookup p m of
    Nothing
        | null ps   -> go
        | otherwise -> recurse M.empty
    Just x
        | null ps   -> go
        | otherwise -> x >>= \v -> case wantVal v of
              Just (s :: AttrSet t) ->
                  recurse (force ?? pure <$> s)
              _ -> evalError @v $ "attribute " ++ show p
                      ++ " is not a set, but a " ++ show v
  where
    go = return $ M.insert p val m

    -- jww (2018-04-13): Need to record positions for attr paths as well
    recurse s = attrSetAlter ps s val <&> \m' ->
        M.insert p (ofVal . fmap (value @_ @_ @m) <$> sequence m') m
-}

evalBinds :: forall e v t m. MonadNixEval e v t m
          => Bool
          -> Bool
          -> [Binding (m v)]
          -> m (AttrSet t)
evalBinds allowDynamic recursive binds = undefined
{-
evalBinds allowDynamic recursive binds = do
    outsideScope <- currentScopes @_ @t
    buildResult . concat =<< mapM (go outsideScope) (moveOverridesLast binds)
  where
    moveOverridesLast = (\(x, y) -> y ++ x) .
        partition (\case NamedVar [StaticKey "__overrides" _] _ -> True
                         _ -> False)

    go :: Scopes m t -> Binding (m v) -> m [([Text], Maybe SourcePos, m v)]
    go _ (NamedVar [StaticKey "__overrides" _] finalValue) =
        finalValue >>= \v -> case wantVal v of
            Just (o', p') ->
                return $ map (\(k, v) -> ([k], M.lookup k p', force v pure))
                             (M.toList o')
            _ -> evalError @v $ "__overrides must be a set, but saw: "
                    ++ show v

    go _ (NamedVar pathExpr finalValue) = do
        let go :: NAttrPath (m v) -> m ([Text], Maybe SourcePos, m v)
            go = \case
                [] -> pure ([], Nothing, finalValue)
                h : t -> evalSetterKeyName allowDynamic h >>= \case
                    (Nothing, _) ->
                        pure ([], Nothing,
                              pure (ofVal (mempty :: AttrSet t)))
                    (Just k, pos) -> do
                        (restOfPath, _, v) <- go t
                        pure (k : restOfPath, pos, v)
        go pathExpr <&> \case
            -- When there are no path segments, e.g. `${null} = 5;`, we don't
            -- bind anything
            ([], _, _) -> []
            result -> [result]

    go outsideScope (Inherit ms names) = fmap catMaybes $ forM names $ \name ->
        evalSetterKeyName allowDynamic name >>= \case
            (Nothing, _) -> return Nothing
            (Just key, pos) -> return $ Just ([key], pos, do
                mv <- case ms of
                    Nothing -> withScopes outsideScope $ lookupVar key
                    Just s -> s >>= \v -> case wantVal v of
                        Just (s :: AttrSet t) ->
                            clearScopes @t $ pushScope s $ lookupVar key
                        _ -> evalError @v $ "Wanted a set, but saw: " ++ show v
                case mv of
                    Nothing -> evalError @v $ "Inheriting unknown attribute: "
                        ++ show (void name)
                    Just v -> force v pure)

    buildResult :: [([Text], Maybe SourcePos, m v)]
                -> m (AttrSet t)
    buildResult bindings = do
        s <- foldM insert M.empty bindings
        scope <- currentScopes @_ @t
        res <- if recursive
               then loebM (encapsulate scope <$> s)
               else traverse (thunk . withScopes scope) s
        traceM $ "buildResult: " ++ show (map (\(k, v, _) -> (k, v)) bindings)
        return (res, foldl' go M.empty bindings)
      where
        -- jww (2018-04-13): Need to record positions for attr paths as well
        go m ([k], Just pos, _) = M.insert k pos m
        go m _ = m

    encapsulate scope f attrs =
        thunk . withScopes scope . pushScope attrs $ f

    insert m (path, _, value) = attrSetAlter path m value
-}

evalSelect :: forall e v t m. MonadNixEval e v t m
           => m v
           -> NAttrPath (m v)
           -> m (Either (v, [Text]) v)
evalSelect aset attr = undefined
{-
    join $ extract <$> aset <*> evalSelector True attr
  where
    extract v [] = return $ Right v
    extract x (k:ks) =
        case wantVal @_ @(AttrSet t) x of
            Just (s, p) -> case M.lookup k s of
                Just v  -> force v $ extract ?? ks
                Nothing -> return $ Left (ofVal (s, p), k:ks)
            Nothing -> return $ Left (x, k:ks)
-}

evalSelector :: MonadEval v m
             => Bool -> NAttrPath (m v) -> m [Text]
evalSelector allowDynamic =
    fmap (map fst) <$> mapM (evalGetterKeyName allowDynamic)

-- | Evaluate a component of an attribute path in a context where we are
-- *retrieving* a value
evalGetterKeyName :: MonadEval v m
                  => Bool -> NKeyName (m v) -> m (Text, Maybe SourcePos)
evalGetterKeyName canBeDynamic
    | canBeDynamic = evalKeyNameDynamicNotNull
    | otherwise    = evalKeyNameStatic

evalKeyNameStatic :: forall v m. MonadEval v m
                  => NKeyName (m v) -> m (Text, Maybe SourcePos)
evalKeyNameStatic = \case
    StaticKey k p -> pure (k, p)
    DynamicKey _ ->
        evalError @v "dynamic attribute not allowed in this context"

evalKeyNameDynamicNotNull :: forall v m. MonadEval v m
                          => NKeyName (m v) -> m (Text, Maybe SourcePos)
evalKeyNameDynamicNotNull = evalKeyNameDynamicNullable >=> \case
    (Nothing, _) ->
        evalError @v "value is null while a string was expected"
    (Just k, p) -> pure (k, p)

-- | Evaluate a component of an attribute path in a context where we are
-- *binding* a value
evalSetterKeyName :: MonadEval v m
                  => Bool -> NKeyName (m v) -> m (Maybe Text, Maybe SourcePos)
evalSetterKeyName canBeDynamic
    | canBeDynamic = evalKeyNameDynamicNullable
    | otherwise    = fmap (first Just) . evalKeyNameStatic

-- | Returns Nothing iff the key value is null
evalKeyNameDynamicNullable :: forall v m. MonadEval v m
                           => NKeyName (m v)
                           -> m (Maybe Text, Maybe SourcePos)
evalKeyNameDynamicNullable = \case
    StaticKey k p -> pure (Just k, p)
    DynamicKey k -> runAntiquoted "\n" (embedMText <=< assembleString) id k
        >>= projectMText >>= \case
            Just (Just (s :: MText v)) ->
                (\x -> (Just x, Nothing)) <$> unwrapMText @v s
            _ -> return (Nothing, Nothing)

assembleString :: forall v m. MonadEval v m => NString (m v) -> m (MText v)
assembleString = \case
    Indented _   parts -> fromParts parts
    DoubleQuoted parts -> fromParts parts
  where
    go = runAntiquoted "\n" (wrapMText @v @m) $ \x -> do
        x' <- x
        projectMText @v @m x' >>= \case
            Just (Just txt) -> return txt
            _ -> evalError @v "Value cannot be rendered as text"

    fromParts parts = mconcat <$> mapM go parts

buildArgument :: forall e v t m. MonadNixEval e v t m
              => Params (m v) -> m v -> m (AttrSet t)
buildArgument params arg = undefined -- case params of
{-
    Param name -> M.singleton name <$> thunk arg
    ParamSet s isVariadic m ->
        arg >>= \v -> case wantVal v of
            Just args -> do
                let inject = case m of
                        Nothing -> id
                        Just n -> M.insert n $ const $ thunk arg
                loebM (inject $ alignWithKey (assemble isVariadic)
                                             args (M.fromList s))
            _ -> evalError @v $ "Argument to function must be a set, but saw: "
                    ++ show v
  where
    assemble :: Bool
             -> Text
             -> These t (Maybe (m v))
             -> AttrSet t
             -> m t
    assemble isVariadic k = \case
        That Nothing  ->
            const $ evalError @v $ "Missing value for parameter: " ++ show k
        That (Just f) -> \args -> do
            scope <- currentScopes @_ @t
            traceM $ "Deferring default argument in scope: " ++ show scope
            thunk $ clearScopes @t $ do
                traceM $ "Evaluating default argument with args: "
                    ++ show (newScope args)
                pushScopes scope $ pushScope args f
        This x | isVariadic -> const (pure x)
               | otherwise  ->
                 const $ evalError @v $ "Unexpected parameter: " ++ show k
        These x _ -> const (pure x)
-}

-----

tracingEvalExpr :: (Framed e m, MonadIO n, Alternative n)
                => (NExprF (m v) -> m v) -> NExprLoc -> n (m v)
tracingEvalExpr eval =
    flip runReaderT (0 :: Int)
        . adiM (pure <$> eval . annotated . getCompose) psi
  where
    psi k v@(Fix x) = do
        depth <- ask
        guard (depth < 200)
        liftIO $ putStrLn $ "eval: " ++ replicate (depth * 2) ' '
            ++ show (stripAnnotation v)
        res <- local succ $
            fmap (withExprContext (void x)) (k v)
        liftIO $ putStrLn $ "eval: " ++ replicate (depth * 2) ' ' ++ "."
        return res

framedEvalExpr :: Framed e m => (NExprF (m v) -> m v) -> NExprLoc -> m v
framedEvalExpr eval = adi (eval . annotated . getCompose) psi
  where
    psi k v@(Fix x) = withExprContext (void x) (k v)

-----

{-
streamValues :: MonadVar m => v -> Stream (EValueF m) m ()
streamValues = void . yields . fmap go
  where
    go (EThunk (Left v)) = streamValues v
    go (EThunk v) = effect (streamValues <$> forceThunk v)
-}
