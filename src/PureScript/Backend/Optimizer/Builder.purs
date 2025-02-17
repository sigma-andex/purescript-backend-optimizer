module PureScript.Backend.Optimizer.Builder
  ( BuildEnv
  , BuildOptions
  , buildModules
  ) where

import Prelude

import Data.FoldableWithIndex (foldrWithIndex)
import Data.List (List, foldM)
import Data.List as List
import Data.Map (Map)
import Data.Map as Map
import Data.Tuple (Tuple)
import PureScript.Backend.Optimizer.Analysis (BackendAnalysis)
import PureScript.Backend.Optimizer.Convert (BackendModule, toBackendModule)
import PureScript.Backend.Optimizer.CoreFn (Ann, Ident, Module(..), Qualified)
import PureScript.Backend.Optimizer.CoreFn.Sort (sortModules)
import PureScript.Backend.Optimizer.Semantics (EvalRef, ExternImpl, InlineDirective)
import PureScript.Backend.Optimizer.Semantics.Foreign (ForeignEval)

type BuildEnv =
  { implementations :: Map (Qualified Ident) (Tuple BackendAnalysis ExternImpl)
  , moduleCount :: Int
  , moduleIndex :: Int
  }

type BuildOptions m =
  { directives :: Map EvalRef InlineDirective
  , foreignSemantics :: Map (Qualified Ident) ForeignEval
  , onPrepareModule :: BuildEnv -> Module Ann -> m (Module Ann)
  , onCodegenModule :: BuildEnv -> Module Ann -> BackendModule -> m Unit
  }

-- | Builds modules given a _sorted_ list of modules.
-- | See `PureScript.Backend.Optimizer.CoreFn.Sort.sortModules`.
buildModules :: forall m. Monad m => BuildOptions m -> List (Module Ann) -> m Unit
buildModules options coreFnModules =
  void $ foldM go { directives: options.directives, implementations: Map.empty, moduleIndex: 0 } (sortModules coreFnModules)
  where
  moduleCount = List.length coreFnModules
  go { directives, implementations, moduleIndex } coreFnModule = do
    let buildEnv = { implementations, moduleCount, moduleIndex }
    coreFnModule'@(Module { name }) <- options.onPrepareModule buildEnv coreFnModule
    let
      backendMod = toBackendModule coreFnModule'
        { currentModule: name
        , currentLevel: 0
        , toLevel: Map.empty
        , implementations
        , moduleImplementations: Map.empty
        , directives
        , dataTypes: Map.empty
        , foreignSemantics: options.foreignSemantics
        , rewriteLimit: 10_000
        }
      newImplementations =
        foldrWithIndex Map.insert implementations backendMod.implementations
    options.onCodegenModule (buildEnv { implementations = newImplementations }) coreFnModule' backendMod
    pure
      { directives: foldrWithIndex Map.insert directives backendMod.directives
      , implementations: newImplementations
      , moduleIndex: moduleIndex + 1
      }
