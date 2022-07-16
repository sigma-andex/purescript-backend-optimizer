module PureScript.Backend.Convert where

import Prelude

import Control.Apply (lift2)
import Control.Monad.RWS (ask)
import Data.Array as Array
import Data.Array.NonEmpty as NonEmptyArray
import Data.Foldable (fold)
import Data.FoldableWithIndex (foldrWithIndex)
import Data.Function (on)
import Data.FunctorWithIndex (mapWithIndex)
import Data.List (List)
import Data.List as List
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Newtype (unwrap)
import Data.Semigroup.Foldable (maximum)
import Data.Set (Set)
import Data.Set as Set
import Data.Traversable (class Foldable, Accum, foldr, mapAccumL, sequence, traverse)
import Data.Tuple (Tuple(..), fst, snd)
import Partial.Unsafe (unsafeCrashWith)
import PureScript.Backend.Analysis (BackendAnalysis)
import PureScript.Backend.Directives (parseDirectiveHeader)
import PureScript.Backend.Semantics (BackendExpr(..), BackendSemantics, Ctx, Env(..), EvalRef(..), ExternImpl(..), ExternSpine, InlineDirective(..), NeutralExpr(..), build, evalExternFromImpl, freeze, optimize)
import PureScript.Backend.Semantics.Foreign (coreForeignSemantics)
import PureScript.Backend.Syntax (BackendAccessor(..), BackendOperator(..), BackendOperator1(..), BackendOperator2(..), BackendOperatorOrd(..), BackendSyntax(..), Level(..), Pair(..))
import PureScript.CoreFn (Ann(..), Bind(..), Binder(..), Binding(..), CaseAlternative(..), CaseGuard(..), ConstructorType(..), Expr(..), Guard(..), Ident, Literal(..), Meta(..), Module(..), ModuleName(..), Prop(..), ProperName, Qualified(..), ReExport(..))

type BackendBindingGroup a b =
  { recursive :: Boolean
  , bindings :: Array (Tuple a b)
  }

type BackendModule =
  { name :: ModuleName
  , imports :: Array ModuleName
  , dataTypes :: Map ProperName DataTypeMeta
  , bindings :: Array (BackendBindingGroup Ident NeutralExpr)
  , exports :: Array (Tuple Ident (Qualified Ident))
  , foreign :: Array Ident
  , implementations :: Map (Qualified Ident) (Tuple BackendAnalysis ExternImpl)
  , directives :: Map EvalRef InlineDirective
  }

type DataTypeMeta =
  { constructors :: Map Ident CtorMeta
  , size :: Int
  }

type CtorMeta =
  { fields :: Array String
  , tag :: Int
  }

type ConvertEnv =
  { currentLevel :: Int
  , currentModule :: ModuleName
  , dataTypes :: Map ProperName DataTypeMeta
  , toLevel :: Map Ident Level
  , implementations :: Map (Qualified Ident) (Tuple BackendAnalysis ExternImpl)
  , deps :: Set ModuleName
  , directives :: Map EvalRef InlineDirective
  , rewriteLimit :: Int
  }

type ConvertM = Function ConvertEnv

toBackendModule :: Module Ann -> ConvertM BackendModule
toBackendModule (Module mod) env = do
  let
    directives =
      parseDirectiveHeader mod.name mod.comments

    ctors = do
      Binding _ _ value <- mod.decls >>= case _ of
        Rec bindings -> bindings
        NonRec binding -> pure binding
      case value of
        ExprConstructor _ dataTy ctor fields ->
          pure $ Tuple dataTy (Tuple ctor fields)
        _ -> []

    dataTypes = ctors
      # Array.groupAllBy (comparing fst)
      # map
          ( \group -> do
              let proper = fst $ NonEmptyArray.head group
              let constructors = Map.fromFoldable $ mapWithIndex (\tag (Tuple _ (Tuple ctor fields)) -> Tuple ctor { fields, tag }) group
              let sizes = Array.length <<< snd <<< snd <$> group
              Tuple proper { constructors, size: maximum sizes }
          )
      # Map.fromFoldable

    moduleBindings =
      toBackendTopLevelBindingGroups mod.decls env
        { dataTypes = dataTypes
        , directives = Map.union directives.locals env.directives
        }

  { name: mod.name
  , imports: Array.filter (not <<< (eq mod.name || eq (ModuleName "Prim"))) $ Set.toUnfoldable moduleBindings.accum.deps
  , dataTypes
  , bindings: moduleBindings.value
  , exports: fold
      [ map (\a -> Tuple a (Qualified Nothing a)) mod.exports
      , map (\(ReExport mn a) -> Tuple a (Qualified (Just mn) a)) mod.reExports
      ]
  , implementations: moduleBindings.accum.implementations
  , directives: directives.exports
  , foreign: mod.foreign
  }

toBackendTopLevelBindingGroups :: Array (Bind Ann) -> ConvertM (Accum ConvertEnv (Array (BackendBindingGroup Ident NeutralExpr)))
toBackendTopLevelBindingGroups binds env = do
  let result = mapAccumL toBackendTopLevelBindingGroup env binds
  result
    { value =
        (\as -> { recursive: (NonEmptyArray.head as).recursive, bindings: _.bindings =<< NonEmptyArray.toArray as }) <$>
          Array.groupBy ((&&) `on` (not <<< _.recursive)) result.value
    }

toBackendTopLevelBindingGroup :: ConvertEnv -> Bind Ann -> Accum ConvertEnv (BackendBindingGroup Ident NeutralExpr)
toBackendTopLevelBindingGroup env = case _ of
  Rec bindings -> do
    let group = (\(Binding _ ident _) -> Qualified (Just env.currentModule) ident) <$> bindings
    mapAccumL (toTopLevelBackendBinding group) env bindings
      # overValue { recursive: true, bindings: _ }
  NonRec binding ->
    mapAccumL (toTopLevelBackendBinding []) env [ binding ]
      # overValue { recursive: false, bindings: _ }
  where
  overValue f a =
    a { value = f a.value }

toTopLevelBackendBinding :: Array (Qualified Ident) -> ConvertEnv ->  Binding Ann -> Accum ConvertEnv (Tuple Ident NeutralExpr)
toTopLevelBackendBinding group env (Binding _ ident cfn) = do
  let evalEnv = Env { currentModule: env.currentModule, evalExtern: makeExternEval env, locals: [], directives: env.directives, try: Nothing }
  let backendExpr = toBackendExpr cfn env
  let Tuple impl expr' = toExternImpl group (optimize (getCtx env) evalEnv (Qualified (Just env.currentModule) ident) env.rewriteLimit backendExpr)
  { accum: env
      { implementations = Map.insert (Qualified (Just env.currentModule) ident) impl env.implementations
      , deps = Set.union (unwrap (fst impl)).deps env.deps
      , directives = case impl of
          Tuple _ (ExternExpr _ (NeutralExpr (App (NeutralExpr (Var qual)) args)))
            | Just (InlineArity n) <- Map.lookup (EvalExtern qual Nothing) env.directives
            , arity <- NonEmptyArray.length args
            , arity < n ->
                Map.insert (EvalExtern (Qualified (Just env.currentModule) ident) Nothing) (InlineArity (n - arity)) env.directives
          _ ->
            env.directives
      }
  , value: Tuple ident expr'
  }

toExternImpl :: Array (Qualified Ident) -> BackendExpr -> Tuple (Tuple BackendAnalysis ExternImpl) NeutralExpr
toExternImpl group expr = case expr of
  ExprSyntax analysis (Lit (LitRecord props)) -> do
    let propsWithAnalysis = map freeze <$> props
    Tuple (Tuple analysis (ExternDict group propsWithAnalysis)) (NeutralExpr (Lit (LitRecord (map snd <$> propsWithAnalysis))))
  ExprSyntax _ (CtorDef ct ty tag fields) -> do
    let Tuple analysis expr' = freeze expr
    Tuple (Tuple analysis (ExternCtor ct ty tag fields)) expr'
  _ -> do
    let Tuple analysis expr' = freeze expr
    Tuple (Tuple analysis (ExternExpr group expr')) expr'

topEnv :: Env -> Env
topEnv (Env env) = Env env { locals = [] }

makeExternEval :: ConvertEnv -> Env -> Qualified Ident -> Array ExternSpine -> Maybe BackendSemantics
makeExternEval conv env qual spine = do
  let
    result = do
      fn <- Map.lookup qual coreForeignSemantics
      fn env qual spine
  case result of
    Nothing -> do
      impl <- Map.lookup qual conv.implementations
      evalExternFromImpl (topEnv env) qual impl spine
    _ ->
      result

data PatternStk
  = PatBinder (Binder Ann) PatternStk
  | PatPush BackendAccessor PatternStk
  | PatPop PatternStk
  | PatNil

buildM :: BackendSyntax BackendExpr -> ConvertM BackendExpr
buildM a env = build (getCtx env) a

getCtx :: ConvertEnv -> Ctx
getCtx env =
  { currentLevel: env.currentLevel
  , lookupExtern: traverse fromExternImpl <=< flip Map.lookup env.implementations
  , effect: false
  }

fromExternImpl :: ExternImpl -> Maybe NeutralExpr
fromExternImpl = case _ of
  ExternExpr _ a -> Just a
  ExternDict _ _ -> Nothing
  ExternCtor _ _ _ _ -> Nothing

levelUp :: forall a. ConvertM a -> ConvertM a
levelUp f env = f (env { currentLevel = env.currentLevel + 1 })

intro :: forall f a. Foldable f => f Ident -> Level -> ConvertM a -> ConvertM a
intro ident lvl f env = f
  ( env
      { currentLevel = env.currentLevel + 1
      , toLevel = foldr (flip Map.insert lvl) env.toLevel ident
      }
  )

currentLevel :: ConvertM Level
currentLevel env = Level env.currentLevel

toBackendExpr :: Expr Ann -> ConvertM BackendExpr
toBackendExpr = case _ of
  ExprVar _ qi -> do
    { currentModule, toLevel } <- ask
    case qi of
      Qualified Nothing ident | Just lvl <- Map.lookup ident toLevel ->
        buildM (Local (Just ident) lvl)
      Qualified (Just mn) ident | mn == currentModule, Just lvl <- Map.lookup ident toLevel ->
        buildM (Local (Just ident) lvl)
      Qualified Nothing ident ->
        buildM (Var (Qualified (Just currentModule) ident))
      _ ->
        buildM (Var qi)
  ExprLit _ lit ->
    buildM <<< Lit =<< traverse toBackendExpr lit
  ExprConstructor _ ty name fields -> do
    { dataTypes } <- ask
    let
      ct = case Map.lookup ty dataTypes of
        Just { constructors } | Map.size constructors == 1 -> ProductType
        _ -> SumType
    buildM (CtorDef ct ty name fields)
  ExprAccessor _ a field ->
    buildM <<< flip Accessor (GetProp field) =<< toBackendExpr a
  ExprUpdate _ a bs ->
    join $ (\x y -> buildM (Update x y))
      <$> toBackendExpr a
      <*> traverse (traverse toBackendExpr) bs
  ExprAbs _ arg body -> do
    lvl <- currentLevel
    make $ Abs (NonEmptyArray.singleton (Tuple (Just arg) lvl)) (intro [ arg ] lvl (toBackendExpr body))
  ExprApp _ a b
    | ExprVar (Ann { meta: Just IsNewtype }) id <- a -> do
        toBackendExpr b
    | otherwise ->
        make $ App (toBackendExpr a) (NonEmptyArray.singleton (toBackendExpr b))
  ExprLet _ binds body ->
    foldr go (toBackendExpr body) binds
    where
    go bind' next = case bind' of
      NonRec (Binding _ ident expr) ->
        makeLet (Just ident) (toBackendExpr expr) \_ -> next
      Rec bindings | Just bindings' <- NonEmptyArray.fromArray bindings -> do
        lvl <- currentLevel
        let idents = (\(Binding _ ident _) -> ident) <$> bindings'
        join $ (\x y -> buildM (LetRec lvl x y))
          <$> intro idents lvl (traverse toBackendBinding bindings')
          <*> intro idents lvl next
      Rec _ ->
        unsafeCrashWith "CoreFn empty Rec binding group"
  ExprCase _ exprs alts -> do
    foldr
      ( \expr next idents ->
          makeLet Nothing (toBackendExpr expr) \tmp ->
            next (Array.snoc idents tmp)
      )
      ( \idents -> do
          env <- identity
          foldr (lift2 (mergeBranches env)) patternFail $ goAlt idents <$> alts
      )
      exprs
      []
  where
  mergeBranches :: ConvertEnv -> BackendExpr -> BackendExpr -> BackendExpr
  mergeBranches _ lhs rhs = case lhs of
    ExprSyntax a1 (Branch bs1 def1) ->
      case rhs of
        ExprSyntax a2 (Branch bs2 def2) ->
          case def1 of
            Nothing ->
              ExprSyntax (a1 <> a2) (Branch (bs1 <> bs2) def2)
            _ ->
              lhs
        _ ->
          case def1 of
            Nothing ->
              ExprSyntax a1 (Branch bs1 (Just rhs))
            _ ->
              lhs
    _ ->
      lhs

  goAlt :: Array Level -> CaseAlternative Ann -> ConvertM BackendExpr
  goAlt idents (CaseAlternative binders branch) =
    goBinders
      ( \renames -> foldr
          ( \(Tuple a b) next ->
              makeLet (Just a) (make (Local Nothing b)) \_ -> next
          )
          (goCaseGuard branch)
          renames
      )
      List.Nil
      (List.fromFoldable idents)
      (foldr (\b s -> PatBinder b (PatPop s)) PatNil binders)

  goCaseGuard :: CaseGuard Ann -> ConvertM BackendExpr
  goCaseGuard = case _ of
    Unconditional expr ->
      toBackendExpr expr
    Guarded gs | Just gs' <- NonEmptyArray.fromArray gs ->
      buildM <<< flip Branch Nothing =<< traverse (\(Guard a b) -> Pair <$> toBackendExpr a <*> toBackendExpr b) gs'
    Guarded _ ->
      unsafeCrashWith "CoreFn empty guarded"

  goBinders
    :: (List (Tuple Ident Level) -> ConvertM BackendExpr)
    -> List (Tuple Ident Level)
    -> List Level
    -> PatternStk
    -> ConvertM BackendExpr
  goBinders k store stk = case _ of
    PatBinder binder next ->
      case binder, stk of
        BinderNull _, _ ->
          makeStep $ goBinders k store stk next
        BinderVar _ a, List.Cons id _ ->
          makeStep $ goBinders k (List.Cons (Tuple a id) store) stk next
        BinderNamed _ a b, List.Cons id _ ->
          makeStep $ goBinders k (List.Cons (Tuple a id) store) stk (PatBinder b next)
        BinderLit _ lit, List.Cons id _ -> do
          case lit of
            LitInt n ->
              makeGuard id (guardInt n) $ goBinders k store stk next
            LitNumber n ->
              makeGuard id (guardNumber n) $ goBinders k store stk next
            LitString n ->
              makeGuard id (guardString n) $ goBinders k store stk next
            LitChar n ->
              makeGuard id (guardChar n) $ goBinders k store stk next
            LitBoolean n ->
              makeGuard id (guardBoolean n) $ goBinders k store stk next
            LitArray bs ->
              makeGuard id (guardArrayLength (Array.length bs)) $ goBinders k store stk $ foldrWithIndex
                ( \ix b s ->
                    PatPush (GetIndex ix) $ PatBinder b $ PatPop s
                )
                next
                bs
            LitRecord ps ->
              makeStep $ goBinders k store stk $ foldr
                ( \(Prop ix b) s ->
                    PatPush (GetProp ix) $ PatBinder b $ PatPop s
                )
                next
                ps
        BinderConstructor (Ann { meta: Just IsNewtype }) _ _ [ b ], _ ->
          goBinders k store stk (PatBinder b next)
        BinderConstructor (Ann { meta }) _ tag bs, List.Cons id _ -> do
          let
            nextBinders = goBinders k store stk $ foldrWithIndex
              ( \ix b s ->
                  PatPush (GetOffset ix) $ PatBinder b $ PatPop s
              )
              next
              bs
          case meta of
            Just (IsConstructor SumType _) ->
              makeGuard id (guardTag tag) nextBinders
            _ ->
              makeStep nextBinders
        _, _ ->
          unsafeCrashWith "impossible: goBinders (binder)"
    PatPush accessor next ->
      case stk of
        List.Cons id _ ->
          makeLet Nothing (make (Accessor (make (Local Nothing id)) accessor)) \tmp ->
            goBinders k store (List.Cons tmp stk) next
        _ ->
          unsafeCrashWith "impossible: goBinders (push)"
    PatPop next ->
      case stk of
        List.Cons _ stk' ->
          goBinders k store stk' next
        List.Nil ->
          unsafeCrashWith "impossible: goBinders (pop)"
    PatNil ->
      k store

  patternFail :: ConvertM (BackendExpr)
  patternFail = make (Fail "Failed pattern match")

  makeLet :: Maybe Ident -> ConvertM BackendExpr -> (Level -> ConvertM BackendExpr) -> ConvertM BackendExpr
  makeLet id a k = do
    lvl <- currentLevel
    case id of
      Nothing ->
        make $ Let id lvl a (levelUp (k lvl))
      Just ident ->
        make $ Let id lvl a (intro [ ident ] lvl (k lvl))

  guardInt :: Int -> _
  guardInt n lhs = PrimOp (Op2 (OpIntOrd OpEq) lhs (make (Lit (LitInt n))))

  guardNumber :: Number -> _
  guardNumber n lhs = PrimOp (Op2 (OpNumberOrd OpEq) lhs (make (Lit (LitNumber n))))

  guardString :: String -> _
  guardString n lhs = PrimOp (Op2 (OpStringOrd OpEq) lhs (make (Lit (LitString n))))

  guardChar :: Char -> _
  guardChar n lhs = PrimOp (Op2 (OpCharOrd OpEq) lhs (make (Lit (LitChar n))))

  guardBoolean :: Boolean -> _
  guardBoolean n lhs = PrimOp (Op2 (OpBooleanOrd OpEq) lhs (make (Lit (LitBoolean n))))

  guardArrayLength :: Int -> _
  guardArrayLength n lhs = guardInt n (make (PrimOp (Op1 OpArrayLength lhs)))

  guardTag :: Qualified Ident -> _
  guardTag n lhs = PrimOp (Op1 (OpIsTag n) lhs)

  makeGuard :: Level -> _ -> ConvertM BackendExpr -> ConvertM BackendExpr
  makeGuard lvl g inner =
    make $ Branch (NonEmptyArray.singleton (Pair (make (g (make (Local Nothing lvl)))) inner)) Nothing

  makeStep :: ConvertM BackendExpr -> ConvertM BackendExpr
  makeStep inner =
    make $ Branch (NonEmptyArray.singleton (Pair (make (Lit (LitBoolean true))) inner)) Nothing

  make :: BackendSyntax (ConvertM BackendExpr) -> ConvertM BackendExpr
  make a = buildM =<< sequence a

toBackendBinding :: Binding Ann -> ConvertM (Tuple Ident BackendExpr)
toBackendBinding (Binding _ ident expr) = Tuple ident <$> toBackendExpr expr
