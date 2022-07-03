module PureScript.Backend.Semantics where

import Prelude

import Control.Alternative (guard)
import Data.Array as Array
import Data.Array.NonEmpty (NonEmptyArray)
import Data.Array.NonEmpty as NonEmptyArray
import Data.Foldable (foldMap, foldl)
import Data.Foldable as Tuple
import Data.Int.Bits (complement, shl, shr, xor, zshr, (.&.), (.|.))
import Data.Lazy (Lazy, defer, force)
import Data.List as List
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Monoid (power)
import Data.Newtype (class Newtype, unwrap)
import Data.String as String
import Data.Tuple (Tuple(..), fst)
import Partial.Unsafe (unsafeCrashWith, unsafePartial)
import PureScript.Backend.Analysis (class HasAnalysis, BackendAnalysis(..), Complexity(..), Usage(..), analysisOf, analyze, bound, withRewrite)
import PureScript.Backend.Syntax (class HasSyntax, BackendAccessor(..), BackendOperator(..), BackendOperator1(..), BackendOperator2(..), BackendOperatorNum(..), BackendOperatorOrd(..), BackendSyntax(..), Level(..), Pair(..), syntaxOf)
import PureScript.CoreFn (ConstructorType, Ident, Literal(..), ModuleName, Prop(..), ProperName, Qualified(..), findProp, propKey)

type Spine a = Array a

type RecSpine a = NonEmptyArray (Tuple Ident (Lazy a))

data MkFn a
  = MkFnApplied a
  | MkFnNext (Maybe Ident) (a -> MkFn a)

data BackendSemantics
  = SemExtern (Qualified Ident) (Array ExternSpine) (Lazy BackendSemantics)
  | SemLam (Maybe Ident) (BackendSemantics -> BackendSemantics)
  | SemMkFn (MkFn BackendSemantics)
  | SemMkEffectFn (MkFn BackendSemantics)
  | SemLet (Maybe Ident) BackendSemantics (BackendSemantics -> BackendSemantics)
  | SemLetRec (NonEmptyArray (Tuple Ident (RecSpine BackendSemantics -> BackendSemantics))) (RecSpine BackendSemantics -> BackendSemantics)
  | SemEffectBind (Maybe Ident) BackendSemantics (BackendSemantics -> BackendSemantics)
  | SemEffectPure BackendSemantics
  | SemBranch (NonEmptyArray (Lazy (SemConditional BackendSemantics))) (Maybe (Lazy BackendSemantics))
  | NeutLocal (Maybe Ident) Level
  | NeutVar (Qualified Ident)
  | NeutStop (Qualified Ident)
  | NeutData (Qualified Ident) ConstructorType ProperName Ident (Array (Tuple String BackendSemantics))
  | NeutCtorDef (Qualified Ident) ConstructorType ProperName Ident (Array String)
  | NeutApp BackendSemantics (Spine BackendSemantics)
  | NeutAccessor BackendSemantics BackendAccessor
  | NeutUpdate BackendSemantics (Array (Prop BackendSemantics))
  | NeutLit (Literal BackendSemantics)
  | NeutFail String
  | NeutUncurriedApp BackendSemantics (Array BackendSemantics)
  | NeutUncurriedEffectApp BackendSemantics (Array BackendSemantics)
  | NeutPrimOp (BackendOperator BackendSemantics)

data SemConditional a = SemConditional a (Maybe (SemTry a) -> a)

type SemTry a = Tuple (Array (Lazy (SemConditional a))) (Maybe (Lazy a))

data BackendExpr
  = ExprSyntax BackendAnalysis (BackendSyntax BackendExpr)
  | ExprRewrite BackendAnalysis BackendRewrite

type LetBindingAssoc a =
  { ident :: Maybe Ident
  , level :: Level
  , binding :: a
  }

data BackendRewrite
  = RewriteInline (Maybe Ident) Level BackendExpr BackendExpr
  | RewriteLetAssoc (Array (LetBindingAssoc BackendExpr)) BackendExpr
  | RewriteStop (Qualified Ident)

data Impl
  = ImplExpr NeutralExpr
  | ImplRec (Array (Qualified Ident)) NeutralExpr
  | ImplDict (Array (Qualified Ident)) (Array (Prop (Tuple BackendAnalysis NeutralExpr)))
  | ImplCtor ConstructorType ProperName Ident (Array String)

instance HasAnalysis BackendExpr where
  analysisOf = case _ of
    ExprSyntax s _ -> s
    ExprRewrite s _ -> s

instance HasSyntax BackendExpr where
  syntaxOf = case _ of
    ExprSyntax _ s -> Just s
    _ -> Nothing

data LocalBinding a = One a | Group (NonEmptyArray (Tuple Ident (Lazy a)))

data ExternSpine
  = ExternApp (Spine BackendSemantics)
  | ExternAccessor BackendAccessor
  | ExternPrimOp BackendOperator1

data EvalRef
  = EvalExtern (Qualified Ident) (Maybe BackendAccessor)
  | EvalLocal (Maybe Ident) Level

derive instance Eq EvalRef
derive instance Ord EvalRef

data InlineDirective
  = InlineNever
  | InlineAlways
  | InlineArity Int

newtype Env = Env
  { currentModule :: ModuleName
  , evalExtern :: Env -> Qualified Ident -> Array ExternSpine -> Maybe BackendSemantics
  , locals :: Array (LocalBinding BackendSemantics)
  , directives :: Map EvalRef InlineDirective
  , try :: Maybe (SemTry BackendSemantics)
  }

derive instance Newtype Env _

lookupLocal :: Env -> Level -> Maybe (LocalBinding BackendSemantics)
lookupLocal (Env { locals }) (Level lvl) = Array.index locals lvl

bindLocal :: Env -> LocalBinding BackendSemantics -> Env
bindLocal (Env env) sem = Env env { locals = Array.snoc env.locals sem }

addDirective :: Env -> EvalRef -> InlineDirective -> Env
addDirective (Env env) ref dir = Env env { directives = Map.insert ref dir env.directives }

addStop :: Env -> EvalRef -> Env
addStop (Env env) ref = Env env
  { directives = Map.alter
      case _ of
        Just InlineAlways ->
          Just InlineAlways
        _ ->
          Just InlineNever
      ref
      env.directives
  }

addTry :: Env -> Maybe (SemTry BackendSemantics) -> Env
addTry (Env env) try = Env env { try = try }

class Eval f where
  eval :: Env -> f -> BackendSemantics

instance Eval f => Eval (BackendSyntax f) where
  eval env = case _ of
    Var qual ->
      evalExtern env qual []
    Local ident lvl ->
      case lookupLocal env lvl of
        Just (One sem) -> sem
        Just (Group group) | Just sem <- flip Tuple.lookup group =<< ident ->
          force sem
        _ ->
          unsafeCrashWith $ "Unbound local at level " <> show (unwrap lvl)
    App hd tl ->
      evalApp env (eval env hd) (NonEmptyArray.toArray (eval env <$> tl))
    UncurriedApp hd tl ->
      NeutUncurriedApp (eval env hd) (eval env <$> tl)
    UncurriedAbs idents body -> do
      let
        loop env' = case _ of
          List.Nil ->
            MkFnApplied (eval env' body)
          List.Cons a as ->
            MkFnNext a \nextArg ->
              loop (bindLocal env' (One nextArg)) as
      SemMkFn (loop env (Array.toUnfoldable $ map fst idents))
    UncurriedEffectApp hd tl ->
      NeutUncurriedEffectApp (eval env hd) (eval env <$> tl)
    UncurriedEffectAbs idents body -> do
      let
        loop env' = case _ of
          List.Nil ->
            MkFnApplied (eval env' body)
          List.Cons a as ->
            MkFnNext a \nextArg ->
              loop (bindLocal env' (One nextArg)) as
      SemMkEffectFn (loop env (Array.toUnfoldable $ map fst idents))
    Abs idents body ->
      foldr1Array
        (\(Tuple ident _) next env' -> SemLam ident (next <<< bindLocal env' <<< One))
        (\(Tuple ident _) env' -> SemLam ident (flip eval body <<< bindLocal env' <<< One))
        idents
        env
    Let ident _ binding body ->
      SemLet ident (eval env binding) (flip eval body <<< bindLocal env <<< One)
    LetRec _ bindings body -> do
      let bindGroup sem = flip eval sem <<< bindLocal env <<< Group
      SemLetRec (map bindGroup <$> bindings) (bindGroup body)
    EffectBind ident _ binding body ->
      SemEffectBind ident (eval env binding) (flip eval body <<< bindLocal env <<< One)
    EffectPure val ->
      SemEffectPure (eval env val)
    Accessor lhs accessor ->
      evalAccessor env (eval env lhs) accessor
    Update lhs updates ->
      evalUpdate env (eval env lhs) (map (eval env) <$> updates)
    Branch branches def -> do
      let conds1 = evalPair env <$> branches
      case def of
        Just def' ->
          evalBranches env conds1 (Just (defer \_ -> eval env def'))
        Nothing ->
          case (unwrap env).try of
            Nothing ->
              evalBranches env conds1 Nothing
            Just (Tuple conds2 def') ->
              evalBranches env (NonEmptyArray.appendArray conds1 conds2) def'
    PrimOp op ->
      evalPrimOp env (eval env <$> op)
    Lit lit ->
      NeutLit (eval env <$> lit)
    Fail err ->
      NeutFail err
    CtorDef ct ty tag fields ->
      NeutCtorDef (Qualified (Just (unwrap env).currentModule) tag) ct ty tag fields
    CtorSaturated qual ct ty tag fields ->
      NeutData qual ct ty tag (map (eval env) <$> fields)

instance Eval BackendExpr where
  eval = go
    where
    go env = case _ of
      ExprRewrite _ rewrite ->
        case rewrite of
          RewriteInline _ _ binding body ->
            go (bindLocal env (One (eval env binding))) body
          RewriteLetAssoc bindings body -> do
            let
              goBinding env' = case _ of
                List.Nil ->
                  eval env' body
                List.Cons b bs ->
                  SemLet b.ident (eval env' b.binding) \nextBinding ->
                    goBinding (bindLocal env (One nextBinding)) bs
            goBinding env (List.fromFoldable bindings)
          RewriteStop qual ->
            NeutStop qual
      ExprSyntax _ expr ->
        eval env expr

instance Eval NeutralExpr where
  eval env (NeutralExpr a) = eval env a

snocApp :: Array ExternSpine -> BackendSemantics -> Array ExternSpine
snocApp prev next = case Array.last prev of
  Just (ExternApp apps) ->
    Array.snoc (Array.dropEnd 1 prev) (ExternApp (Array.snoc apps next))
  _ ->
    Array.snoc prev (ExternApp [ next ])

evalApp :: Env -> BackendSemantics -> Spine BackendSemantics -> BackendSemantics
evalApp env hd spine
  | Array.null spine = hd
  | otherwise = go env hd (List.fromFoldable spine)
      where
      go env' = case _, _ of
        SemLam _ k, List.Cons arg args ->
          SemLet Nothing arg \nextArg ->
            go env' (k nextArg) args
        SemExtern qual sp _, List.Cons arg args -> do
          go env' (evalExtern env' qual (snocApp sp arg)) args
        SemLet ident val k, args ->
          SemLet ident val \nextVal ->
            SemLet Nothing (k nextVal) \nextFn ->
              go (bindLocal (bindLocal env' (One nextVal)) (One nextFn)) nextFn args
        fn, List.Nil ->
          fn
        fn, args ->
          NeutApp fn (List.toUnfoldable args)

evalSpine :: Env -> BackendSemantics -> Array ExternSpine -> BackendSemantics
evalSpine env = foldl go
  where
  go hd = case _ of
    ExternApp spine ->
      evalApp env hd spine
    ExternAccessor accessor ->
      evalAccessor env hd accessor
    ExternPrimOp op1 ->
      evalPrimOp env (Op1 op1 hd)

neutralSpine :: BackendSemantics -> Array ExternSpine -> BackendSemantics
neutralSpine = foldl go
  where
  go hd = case _ of
    ExternApp apps ->
      NeutApp hd apps
    ExternAccessor acc ->
      NeutAccessor hd acc
    ExternPrimOp op1 ->
      NeutPrimOp (Op1 op1 hd)

neutralApp :: BackendSemantics -> Spine BackendSemantics -> BackendSemantics
neutralApp hd spine
  | Array.null spine =
      hd
  | otherwise = case hd of
      NeutApp hd' spine' ->
        NeutApp hd' (spine' <> spine)
      _ ->
        NeutApp hd spine

evalAccessor :: Env -> BackendSemantics -> BackendAccessor -> BackendSemantics
evalAccessor initEnv initLhs accessor =
  evalAssocLet initEnv initLhs \env lhs -> case lhs of
    SemExtern qual spine _ ->
      evalExtern env qual $ Array.snoc spine (ExternAccessor accessor)
    NeutLit (LitRecord props)
      | GetProp prop <- accessor
      , Just sem <- Array.findMap (\(Prop p v) -> guard (p == prop) $> v) props ->
          sem
    NeutLit (LitArray values)
      | GetIndex n <- accessor
      , Just sem <- Array.index values n ->
          sem
    NeutData _ _ _ _ fields
      | GetOffset n <- accessor
      , Just (Tuple _ sem) <- Array.index fields n ->
          sem
    _ ->
      NeutAccessor lhs accessor

evalUpdate :: Env -> BackendSemantics -> Array (Prop BackendSemantics) -> BackendSemantics
evalUpdate initEnv initLhs props =
  evalAssocLet initEnv initLhs \_ lhs -> case lhs of
    NeutLit (LitRecord props') ->
      NeutLit (LitRecord (NonEmptyArray.head <$> Array.groupAllBy (comparing propKey) (props <> props')))
    _ ->
      NeutUpdate lhs props

evalBranches :: Env -> NonEmptyArray (Lazy (SemConditional BackendSemantics)) -> Maybe (Lazy BackendSemantics) -> BackendSemantics
evalBranches _ initConds initDef = go [] (NonEmptyArray.toArray initConds) initDef
  where
  go acc conds def = case Array.uncons conds of
    Just { head, tail } ->
      case force head of
        SemConditional (NeutLit (LitBoolean didMatch)) k ->
          if didMatch then
            go acc [] (Just (defer \_ -> k (Just (Tuple tail def))))
          else
            go acc tail def
        _ ->
          go (Array.snoc acc head) tail def
    Nothing ->
      case NonEmptyArray.fromArray acc of
        Just bs ->
          SemBranch bs def
        Nothing ->
          case def of
            Just sem ->
              force sem
            Nothing ->
              NeutFail "Failed pattern match"

evalPair :: forall f. Eval f => Env -> Pair f -> Lazy (SemConditional BackendSemantics)
evalPair env (Pair a b) = defer \_ -> SemConditional (eval env a) (flip eval b <<< addTry env)

evalAssocLet :: Env -> BackendSemantics -> (Env -> BackendSemantics -> BackendSemantics) -> BackendSemantics
evalAssocLet env sem go = case sem of
  SemLet ident val k ->
    SemLet ident val \nextVal1 ->
      SemLet Nothing (k nextVal1) \nextVal2 ->
        go (bindLocal (bindLocal env (One nextVal1)) (One nextVal2)) nextVal2
  _ ->
    go env sem

evalAssocLet2
  :: Env
  -> BackendSemantics
  -> BackendSemantics
  -> (Env -> BackendSemantics -> BackendSemantics -> BackendSemantics)
  -> BackendSemantics
evalAssocLet2 env sem1 sem2 go =
  evalAssocLet env sem1 \env' sem1' ->
    evalAssocLet env' sem2 \env'' sem2' ->
      go env'' sem1' sem2'

-- TODO: Check for overflow in Int ops since backends may not handle it the
-- same was as the JS backend.
evalPrimOp :: Env -> BackendOperator BackendSemantics -> BackendSemantics
evalPrimOp env = case _ of
  Op1 op1 x ->
    case op1, x of
      OpBooleanNot, NeutLit (LitBoolean bool) ->
        liftBoolean (not bool)
      OpBooleanNot, NeutPrimOp op ->
        evalPrimOpNot op
      OpIntBitNot, NeutLit (LitInt a) ->
        liftInt (complement a)
      OpIsTag a, NeutData b _ _ _ _ ->
        liftBoolean (a == b)
      OpArrayLength, NeutLit (LitArray arr) ->
        liftInt (Array.length arr)
      _, SemExtern qual spine _ ->
        evalExtern env qual $ Array.snoc spine (ExternPrimOp op1)
      _, _ ->
        evalAssocLet env x \_ x' ->
          NeutPrimOp (Op1 op1 x')
  Op2 op2 x y ->
    case op2 of
      OpBooleanAnd
        | NeutLit (LitBoolean false) <- x ->
            x
        | NeutLit (LitBoolean false) <- y ->
            y
        | NeutLit (LitBoolean true) <- x
        , NeutLit (LitBoolean true) <- y ->
            x
      OpBooleanOr
        | NeutLit (LitBoolean false) <- x ->
            y
        | NeutLit (LitBoolean false) <- y ->
            x
        | NeutLit (LitBoolean true) <- x ->
            x
        | NeutLit (LitBoolean true) <- y ->
            y
      OpBooleanOrd OpEq
        | NeutLit (LitBoolean bool) <- x ->
            if bool then y else evalPrimOp env (Op1 OpBooleanNot y)
        | NeutLit (LitBoolean bool) <- y ->
            if bool then x else evalPrimOp env (Op1 OpBooleanNot x)
      OpBooleanOrd op
        | NeutLit (LitBoolean a) <- x
        , NeutLit (LitBoolean b) <- y ->
            liftBoolean (evalPrimOpOrd op a b)
      OpCharOrd op
        | NeutLit (LitChar a) <- x
        , NeutLit (LitChar b) <- y ->
            liftBoolean (evalPrimOpOrd op a b)
      OpIntBitAnd
        | NeutLit (LitInt a) <- x
        , NeutLit (LitInt b) <- y ->
            liftInt (a .&. b)
      OpIntBitOr
        | NeutLit (LitInt a) <- x
        , NeutLit (LitInt b) <- y ->
            liftInt (a .|. b)
      OpIntBitShiftLeft
        | NeutLit (LitInt a) <- x
        , NeutLit (LitInt b) <- y ->
            liftInt (shl a b)
      OpIntBitShiftRight
        | NeutLit (LitInt a) <- x
        , NeutLit (LitInt b) <- y ->
            liftInt (shr a b)
      OpIntBitXor
        | NeutLit (LitInt a) <- x
        , NeutLit (LitInt b) <- y ->
            liftInt (xor a b)
      OpIntBitZeroFillShiftRight
        | NeutLit (LitInt a) <- x
        , NeutLit (LitInt b) <- y ->
            liftInt (zshr a b)
      OpIntNum op
        | NeutLit (LitInt a) <- x
        , NeutLit (LitInt b) <- y ->
            liftInt (evalPrimOpNum op a b)
      OpIntOrd op
        | NeutLit (LitInt a) <- x
        , NeutLit (LitInt b) <- y ->
            liftBoolean (evalPrimOpOrd op a b)
      OpNumberNum op
        | NeutLit (LitNumber a) <- x
        , NeutLit (LitNumber b) <- y ->
            liftNumber (evalPrimOpNum op a b)
      OpNumberOrd op
        | NeutLit (LitNumber a) <- x
        , NeutLit (LitNumber b) <- y ->
            liftBoolean (evalPrimOpOrd op a b)
      OpStringOrd op
        | NeutLit (LitString a) <- x
        , NeutLit (LitString b) <- y ->
            liftBoolean (evalPrimOpOrd op a b)
      OpStringAppend
        | Just result <- evalPrimOpAssocL OpStringAppend caseString (\a b -> liftString (a <> b)) x y ->
            result
      _ ->
        evalAssocLet2 env x y \_ x' y' ->
          NeutPrimOp (Op2 op2 x' y')

evalPrimOpAssocL :: forall a. BackendOperator2 -> (BackendSemantics -> Maybe a) -> (a -> a -> BackendSemantics) -> BackendSemantics -> BackendSemantics -> Maybe BackendSemantics
evalPrimOpAssocL op match combine a b = case match a of
  Just lhs
    | Just rhs <- match b ->
        Just $ combine lhs rhs
    | Just (Tuple x y) <- decompose b ->
        case match x of
          Just rhs ->
            Just $ liftOp2 op (combine lhs rhs) y
          Nothing
            | Just (Tuple v w) <- decompose x
            , Just rhs <- match v ->
                Just $ liftOp2 op (liftOp2 op (combine lhs rhs) w) y
          _ ->
            Nothing
  Nothing
    | Just rhs <- match b
    , Just (Tuple v w) <- decompose a ->
        case match w of
          Just lhs ->
            Just $ liftOp2 op v (combine lhs rhs)
          Nothing
            | Just (Tuple x y) <- decompose w
            , Just lhs <- match y ->
                Just $ liftOp2 op (liftOp2 op v x) (combine lhs rhs)
          _ ->
            Nothing
  _ ->
    Nothing
  where
  decompose = case _ of
    NeutPrimOp (Op2 op' x y) | op == op' ->
      Just (Tuple x y)
    _ ->
      Nothing

evalPrimOpOrd :: forall a. Ord a => BackendOperatorOrd -> a -> a -> Boolean
evalPrimOpOrd op x y = case op of
  OpEq -> x == y
  OpNotEq -> x /= y
  OpGt -> x > y
  OpGte -> x >= y
  OpLt -> x < y
  OpLte -> x <= y

evalPrimOpNum :: forall a. EuclideanRing a => BackendOperatorNum -> a -> a -> a
evalPrimOpNum op x y = case op of
  OpAdd -> x + y
  OpDivide -> x / y
  OpMultiply -> x * y
  OpSubtract -> x - y

evalPrimOpNot :: BackendOperator BackendSemantics -> BackendSemantics
evalPrimOpNot = case _ of
  Op1 op x ->
    case op of
      OpBooleanNot ->
        x
      _ ->
        liftOp1 OpBooleanNot (liftOp1 op x)
  Op2 op x y ->
    case op of
      OpIntOrd ord ->
        liftOp2 (OpIntOrd (primOpOrdNot ord)) x y
      OpNumberOrd ord ->
        liftOp2 (OpNumberOrd (primOpOrdNot ord)) x y
      OpStringOrd ord ->
        liftOp2 (OpStringOrd (primOpOrdNot ord)) x y
      OpCharOrd ord ->
        liftOp2 (OpCharOrd (primOpOrdNot ord)) x y
      OpBooleanOrd ord ->
        liftOp2 (OpBooleanOrd (primOpOrdNot ord)) x y
      _ ->
        liftOp1 OpBooleanNot (liftOp2 op x y)

primOpOrdNot :: BackendOperatorOrd -> BackendOperatorOrd
primOpOrdNot = case _ of
  OpEq -> OpNotEq
  OpNotEq -> OpEq
  OpLt -> OpGte
  OpLte -> OpGt
  OpGt -> OpLte
  OpGte -> OpLt

evalExtern :: Env -> Qualified Ident -> Array ExternSpine -> BackendSemantics
evalExtern env@(Env e) qual spine = case spine of
  [] | Just InlineNever <- Map.lookup (EvalExtern qual Nothing) e.directives ->
    NeutStop qual
  [ ExternAccessor acc ] | Just InlineNever <- Map.lookup (EvalExtern qual (Just acc)) e.directives ->
    neutralSpine (NeutStop qual) spine
  _ ->
    case e.evalExtern env qual spine of
      Just sem ->
        sem
      Nothing ->
        SemExtern qual spine (defer \_ -> neutralSpine (NeutVar qual) spine)

evalExternFromImpl :: Env -> Qualified Ident -> Tuple BackendAnalysis Impl -> Array ExternSpine -> Maybe BackendSemantics
evalExternFromImpl env@(Env e) qual (Tuple analysis impl) spine = case impl of
  ImplExpr expr -> do
    let directive = Map.lookup (EvalExtern qual Nothing) e.directives
    case expr, spine of
      NeutralExpr (Var _), [] ->
        Just $ eval env expr
      NeutralExpr (Lit lit), [] | shouldInlineExternLiteral lit directive ->
        Just $ eval env expr
      body, [ ExternApp args ] | shouldInlineExternApp qual analysis body args directive ->
        Just $ evalApp env (eval env body) args
      _, _ ->
        Nothing
  ImplCtor ct ty tag fields ->
    case fields, spine of
      [], [] ->
        Just $ NeutData qual ct ty tag []
      _, [ ExternApp args ] | Array.length fields == Array.length args ->
        Just $ NeutData qual ct ty tag $ Array.zip fields args
      _, _ ->
        Nothing
  ImplDict group props ->
    case spine of
      [ ExternAccessor acc@(GetProp prop), ExternApp args ] | Just (Tuple analysis' body) <- findProp prop props -> do
        let ref = EvalExtern qual (Just acc)
        let directive = Map.lookup ref e.directives
        if shouldInlineExternApp qual analysis' body args directive then do
          let env' = if Array.null group then env else addStop env ref
          Just $ evalApp env (eval env' body) args
        else
          Nothing
      [ ExternAccessor acc@(GetProp prop) ] | Just (Tuple analysis' body) <- findProp prop props -> do
        let ref = EvalExtern qual (Just acc)
        let directive = Map.lookup ref e.directives
        if shouldInlineExternAccessor qual analysis' body acc directive then do
          let env' = if Array.null group then env else addStop env ref
          Just $ eval env' body
        else
          Nothing
      _ ->
        Nothing
  _ ->
    Nothing

externRefFromSpine :: Qualified Ident -> Array ExternSpine -> EvalRef
externRefFromSpine qual spine = case Array.head spine of
  Just (ExternAccessor acc) ->
    EvalExtern qual (Just acc)
  _ ->
    EvalExtern qual Nothing

analysisFromDirective :: BackendAnalysis -> InlineDirective -> BackendAnalysis
analysisFromDirective (BackendAnalysis analysis) = case _ of
  InlineAlways ->
    mempty
  InlineNever ->
    BackendAnalysis analysis { complexity = NonTrivial, size = top }
  InlineArity n ->
    BackendAnalysis analysis { args = Array.take n analysis.args }

liftBoolean :: Boolean -> BackendSemantics
liftBoolean = NeutLit <<< LitBoolean

liftInt :: Int -> BackendSemantics
liftInt = NeutLit <<< LitInt

liftNumber :: Number -> BackendSemantics
liftNumber = NeutLit <<< LitNumber

liftString :: String -> BackendSemantics
liftString = NeutLit <<< LitString

liftOp1 :: BackendOperator1 -> BackendSemantics -> BackendSemantics
liftOp1 op a = NeutPrimOp (Op1 op a)

liftOp2 :: BackendOperator2 -> BackendSemantics -> BackendSemantics -> BackendSemantics
liftOp2 op a b = NeutPrimOp (Op2 op a b)

caseString :: BackendSemantics -> Maybe String
caseString = case _ of
  NeutLit (LitString a) -> Just a
  _ -> Nothing

foldr1Array :: forall a b. (a -> b -> b) -> (a -> b) -> NonEmptyArray a -> b
foldr1Array f g arr = go (NonEmptyArray.length arr - 2) (g (NonEmptyArray.last arr))
  where
  go ix acc
    | ix < 0 = acc
    | otherwise =
        go (ix - 1) (f (unsafePartial (NonEmptyArray.unsafeIndex arr ix)) acc)

foldl1Array :: forall a b. (b -> a -> b) -> (a -> b) -> NonEmptyArray a -> b
foldl1Array f g arr = go 0 (g (NonEmptyArray.head arr))
  where
  len = NonEmptyArray.length arr
  go ix acc
    | ix == len = acc
    | otherwise =
        go (ix + 1) (f acc (unsafePartial (NonEmptyArray.unsafeIndex arr ix)))

type Ctx =
  { currentLevel :: Int
  , lookupExtern :: Qualified Ident -> Maybe (Tuple BackendAnalysis NeutralExpr)
  }

nextLevel :: Ctx -> Tuple Level Ctx
nextLevel ctx = Tuple (Level ctx.currentLevel) $ ctx { currentLevel = ctx.currentLevel + 1 }

quote :: Ctx -> BackendSemantics -> BackendExpr
quote = go
  where
  go ctx = case _ of
    SemExtern _ _ sem ->
      go ctx (force sem)
    SemLam ident k -> do
      let Tuple level ctx' = nextLevel ctx
      build ctx $ Abs (NonEmptyArray.singleton (Tuple ident level)) $ quote ctx' $ k $ NeutLocal ident level
    SemMkFn pro -> do
      let
        loop ctx' idents = case _ of
          MkFnNext ident k -> do
            let Tuple lvl ctx'' = nextLevel ctx'
            loop ctx'' (Array.snoc idents (Tuple ident lvl)) (k (NeutLocal ident lvl))
          MkFnApplied body ->
            build ctx' $ UncurriedAbs idents $ quote ctx' body
      loop ctx [] pro
    SemMkEffectFn pro -> do
      let
        loop ctx' idents = case _ of
          MkFnNext ident k -> do
            let Tuple lvl ctx'' = nextLevel ctx'
            loop ctx'' (Array.snoc idents (Tuple ident lvl)) (k (NeutLocal ident lvl))
          MkFnApplied body ->
            build ctx' $ UncurriedEffectAbs idents $ quote ctx' body
      loop ctx [] pro
    SemLet ident binding k -> do
      let Tuple level ctx' = nextLevel ctx
      build ctx $ Let ident level (quote ctx binding) $ quote ctx' $ k $ NeutLocal ident level
    SemLetRec bindings k -> do
      let Tuple level ctx' = nextLevel ctx
      let neutBindings = (\(Tuple ident _) -> Tuple ident $ defer \_ -> NeutLocal (Just ident) level) <$> bindings
      build ctx $ LetRec level
        (map (\b -> quote ctx' $ b neutBindings) <$> bindings)
        (quote ctx' $ k neutBindings)
    SemEffectBind ident binding k -> do
      let Tuple level ctx' = nextLevel ctx
      build ctx $ EffectBind ident level (quote ctx binding) $ quote ctx' $ k $ NeutLocal ident level
    SemEffectPure sem ->
      build ctx $ EffectPure (quote ctx sem)
    SemBranch branches def -> do
      let quoteCond (SemConditional a k) = buildPair ctx (quote ctx a) (quote ctx (k Nothing))
      let branches' = quoteCond <<< force <$> branches
      case quote ctx <<< force <$> def of
        Just def' ->
          foldr1Array (buildBranchCond ctx) (flip (buildBranchCond ctx) def') branches'
        Nothing ->
          build ctx $ Branch branches' Nothing
    NeutLocal ident level ->
      build ctx $ Local ident level
    NeutVar qual ->
      build ctx $ Var qual
    NeutStop qual ->
      buildStop ctx qual
    NeutData qual _ _ _ [] ->
      build ctx $ Var qual
    NeutData qual ct ty tag values ->
      build ctx $ CtorSaturated qual ct ty tag (map (quote ctx) <$> values)
    NeutCtorDef _ ct ty tag fields ->
      build ctx $ CtorDef ct ty tag fields
    NeutUncurriedApp hd spine -> do
      let hd' = quote ctx hd
      build ctx $ UncurriedApp hd' (quote ctx <$> spine)
    NeutUncurriedEffectApp hd spine -> do
      let hd' = quote ctx hd
      build ctx $ UncurriedEffectApp hd' (quote ctx <$> spine)
    NeutApp hd spine -> do
      let hd' = quote ctx hd
      case NonEmptyArray.fromArray (quote ctx <$> spine) of
        Nothing ->
          hd'
        Just args ->
          build ctx $ App hd' args
    NeutAccessor lhs accessor ->
      build ctx $ Accessor (quote ctx lhs) accessor
    NeutUpdate lhs props ->
      build ctx $ Update (quote ctx lhs) (map (quote ctx) <$> props)
    NeutLit lit ->
      build ctx $ Lit (quote ctx <$> lit)
    NeutPrimOp op ->
      build ctx $ PrimOp (quote ctx <$> op)
    NeutFail err ->
      build ctx $ Fail err

build :: Ctx -> BackendSyntax BackendExpr -> BackendExpr
build ctx = case _ of
  App (ExprSyntax _ (App hd tl1)) tl2 ->
    build ctx $ App hd (tl1 <> tl2)
  Abs ids1 (ExprSyntax _ (Abs ids2 body)) ->
    build ctx $ Abs (ids1 <> ids2) body
  expr@(Let ident1 level1 (ExprSyntax _ (Let ident2 level2 binding2 body2)) body1) ->
    ExprRewrite (withRewrite (analyzeDefault ctx expr)) $ RewriteLetAssoc
      [ { ident: ident2, level: level2, binding: binding2 }
      , { ident: ident1, level: level1, binding: body2 }
      ]
      body1
  expr@(Let ident1 level1 (ExprRewrite _ (RewriteLetAssoc bindings body2)) body1) ->
    ExprRewrite (withRewrite (analyzeDefault ctx expr)) $ RewriteLetAssoc
      (Array.snoc bindings { ident: ident1, level: level1, binding: body2 })
      body1
  Let ident level binding body
    | shouldInlineLet level binding body ->
        rewriteInline ident level binding body
  -- TODO: Multi argument eta reduction?
  -- TODO: Don't eta reduce recursive bindings.
  -- Abs args (ExprSyntax _ (App hd@(ExprSyntax _ fn) spine))
  --   | isReference fn
  --   , [ Tuple _ lvl1 ] <- NonEmptyArray.toArray args
  --   , [ ExprSyntax _ (Local _ lvl2) ] <- NonEmptyArray.toArray spine
  --   , lvl1 == lvl2 ->
  --       hd
  EffectBind ident level (ExprSyntax _ (EffectPure binding)) body ->
    build ctx $ Let ident level binding body
  Branch pairs (Just def) | Just expr <- simplifyBranches ctx pairs def ->
    expr
  PrimOp (Op1 OpBooleanNot (ExprSyntax _ (PrimOp (Op1 OpBooleanNot expr)))) ->
    expr
  expr ->
    buildDefault ctx expr

buildPair :: Ctx -> BackendExpr -> BackendExpr -> Pair BackendExpr
buildPair ctx p1 = case _ of
  ExprSyntax _ (Branch bs Nothing)
    | [ Pair p2 b ] <- NonEmptyArray.toArray bs ->
        Pair (build ctx $ PrimOp (Op2 OpBooleanAnd p1 p2)) b
  p2 ->
    Pair p1 p2

buildBranchCond :: Ctx -> Pair BackendExpr -> BackendExpr -> BackendExpr
buildBranchCond ctx (Pair a b) c = case b of
  ExprSyntax _ (Lit (LitBoolean bool1))
    | ExprSyntax _ (Lit (LitBoolean bool2)) <- c ->
        if bool1 then
          if bool2 then c
          else a
        else if bool2 then c
        else build ctx (PrimOp (Op1 OpBooleanNot a))
    | ExprSyntax _ x <- c, isBooleanTail x ->
        if bool1 then
          build ctx (PrimOp (Op2 OpBooleanOr a c))
        else
          build ctx (PrimOp (Op2 OpBooleanOr (build ctx (PrimOp (Op1 OpBooleanNot a))) c))
  _ ->
    build ctx (Branch (NonEmptyArray.singleton (Pair a b)) (Just c))

isBooleanTail :: forall a. BackendSyntax a -> Boolean
isBooleanTail = case _ of
  Lit _ -> true
  Var _ -> true
  Local _ _ -> true
  PrimOp _ -> true
  _ -> false

simplifyBranches :: Ctx -> NonEmptyArray (Pair BackendExpr) -> BackendExpr -> Maybe BackendExpr
simplifyBranches ctx pairs def = case NonEmptyArray.toArray pairs of
  [ a ]
    | Pair expr (ExprSyntax _ (Lit (LitBoolean true))) <- a
    , ExprSyntax _ (Lit (LitBoolean false)) <- def ->
        Just expr
    | Pair expr (ExprSyntax _ (Lit (LitBoolean false))) <- a
    , ExprSyntax _ (Lit (LitBoolean true)) <- def ->
        Just $ build ctx $ PrimOp (Op1 OpBooleanNot expr)
  [ a, b ]
    | Pair expr1@(ExprSyntax _ (Local _ lvl1)) body1 <- a
    , Pair (ExprSyntax _ (PrimOp (Op1 OpBooleanNot (ExprSyntax _ (Local _ lvl2))))) body2 <- b
    , ExprSyntax _ (Fail _) <- def
    , lvl1 == lvl2 ->
        Just $ build ctx $ Branch (NonEmptyArray.singleton (Pair expr1 body1)) (Just body2)
  _
    | ExprSyntax _ (Branch pairs2 def2) <- def ->
        Just $ build ctx (Branch (pairs <> pairs2) def2)
    | otherwise ->
        Nothing

buildStop :: Ctx -> Qualified Ident -> BackendExpr
buildStop ctx stop = ExprRewrite (analyzeDefault ctx (Var stop)) (RewriteStop stop)

buildDefault :: Ctx -> BackendSyntax BackendExpr -> BackendExpr
buildDefault ctx expr = ExprSyntax (analyzeDefault ctx expr) expr

analyzeDefault :: Ctx -> BackendSyntax BackendExpr -> BackendAnalysis
analyzeDefault ctx = analyze (foldMap fst <<< ctx.lookupExtern)

rewriteInline :: Maybe Ident -> Level -> BackendExpr -> BackendExpr -> BackendExpr
rewriteInline ident level binding body = do
  let
    s2 = analysisOf body
    powAnalysis = case Map.lookup level (unwrap s2).usages of
      Just (Usage { count }) ->
        -- TODO: There may be more work to be done here wrt size.
        s2 <> power (analysisOf binding) count
      Nothing ->
        s2
  ExprRewrite (withRewrite (bound level powAnalysis)) $ RewriteInline ident level binding body

isReference :: forall a. BackendSyntax a -> Boolean
isReference = case _ of
  Var _ -> true
  Local _ _ -> true
  _ -> false

shouldInlineLet :: Level -> BackendExpr -> BackendExpr -> Boolean
shouldInlineLet level a b = do
  let BackendAnalysis s1 = analysisOf a
  let BackendAnalysis s2 = analysisOf b
  case Map.lookup level s2.usages of
    Nothing ->
      true
    Just (Usage { captured, count }) ->
      (s1.complexity == Trivial && s1.size < 5)
        || (not captured && (count == 1 || (s1.complexity <= Deref && s1.size < 5)))
        || (isAbs a && (count == 1 || Map.isEmpty s1.usages || s1.size < 16))

shouldInlineExternApp :: Qualified Ident -> BackendAnalysis -> NeutralExpr -> Spine BackendSemantics -> Maybe InlineDirective -> Boolean
shouldInlineExternApp _ (BackendAnalysis s) _ args = case _ of
  Just dir ->
    case dir of
      InlineAlways -> true
      InlineNever -> false
      InlineArity n -> Array.length args == n
  _ ->
    (s.complexity == Trivial && s.size < 5)
      || (s.complexity <= Deref && s.size < 5)
      || (Array.length s.args > 0 && Array.length s.args <= Array.length args && s.size < 16)

shouldInlineExternAccessor :: Qualified Ident -> BackendAnalysis -> NeutralExpr -> BackendAccessor -> Maybe InlineDirective -> Boolean
shouldInlineExternAccessor _ (BackendAnalysis s) _ _ = case _ of
  Just InlineAlways -> true
  Just InlineNever -> false
  _ ->
    (s.complexity == Trivial && s.size < 5)
      || (s.complexity <= Deref && s.size < 5)

shouldInlineExternLiteral :: Literal NeutralExpr -> Maybe InlineDirective -> Boolean
shouldInlineExternLiteral lit = case _ of
  Just InlineAlways -> true
  Just InlineNever -> false
  _ ->
    case lit of
      LitInt _ -> true
      LitNumber _ -> true
      LitString s -> String.length s <= 32
      LitChar _ -> true
      LitBoolean _ -> true
      LitArray a -> Array.null a
      LitRecord r -> Array.null r

isAbs :: BackendExpr -> Boolean
isAbs = syntaxOf >>> case _ of
  Just (Abs _ _) -> true
  _ -> false

newtype NeutralExpr = NeutralExpr (BackendSyntax NeutralExpr)

derive instance Newtype NeutralExpr _

optimize :: Ctx -> Env -> BackendExpr -> BackendExpr
optimize ctx env expr1 = do
  let expr2 = quote ctx (eval env expr1)
  case expr2 of
    ExprSyntax (BackendAnalysis { rewrite }) _ | not rewrite ->
      expr2
    _ ->
      optimize ctx env expr2

freeze :: BackendExpr -> Tuple BackendAnalysis NeutralExpr
freeze init = Tuple (analysisOf init) (go init)
  where
  go = case _ of
    ExprSyntax _ expr ->
      NeutralExpr $ go <$> expr
    ExprRewrite _ rewrite ->
      case rewrite of
        RewriteInline ident level binding body ->
          NeutralExpr $ Let ident level (go binding) (go body)
        RewriteStop qual ->
          NeutralExpr $ Var qual
        RewriteLetAssoc bindings body ->
          case NonEmptyArray.fromArray bindings of
            Just bindings' -> do
              let
                { ident, level, binding } = foldl1Array
                  ( \inner outer -> outer
                      { binding =
                          NeutralExpr $ Let inner.ident inner.level inner.binding (go outer.binding)
                      }
                  )
                  (\outer -> outer { binding = go outer.binding })
                  bindings'
              NeutralExpr $ Let ident level binding (go body)
            Nothing ->
              go body

evalMkFn :: Env -> Int -> BackendSemantics -> MkFn BackendSemantics
evalMkFn env n sem
  | n == 0 = MkFnApplied sem
  | otherwise =
      case sem of
        SemLam ident k -> do
          MkFnNext ident (evalMkFn env (n - 1) <<< k)
        _ ->
          MkFnNext Nothing \nextArg -> do
            let env' = bindLocal env (One nextArg)
            evalMkFn env' (n - 1) (evalApp env' sem [ nextArg ])
