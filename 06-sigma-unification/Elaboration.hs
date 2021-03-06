
module Elaboration (check, infer) where

import Control.Exception
import Control.Monad

import qualified Data.Map.Strict as M

import Common
import Cxt
import Errors
import Evaluation
import Syntax
import Unification
import Value

import qualified Presyntax as P

--------------------------------------------------------------------------------

unifyCatch :: Cxt -> Val -> Val -> IO ()
unifyCatch cxt t t' =
  unify (lvl cxt) t t'
  `catch` \UnifyError ->
    throwIO $ Error cxt $ CantUnify (quote (lvl cxt) t) (quote (lvl cxt) t')

-- | Insert fresh implicit applications.
insert' :: Cxt -> IO (Tm, VTy) -> IO (Tm, VTy)
insert' cxt act = go =<< act where
  go (t, va) = case force va of
    VPi x Impl a b -> do
      m <- freshMeta cxt a
      let mv = eval (env cxt) m
      go (App t m Impl, b $$ mv)
    va -> pure (t, va)

-- | Insert fresh implicit applications to a term which is not
--   an implicit lambda (i.e. neutral).
insert :: Cxt -> IO (Tm, VTy) -> IO (Tm, VTy)
insert cxt act = act >>= \case
  (t@(Lam _ Impl _), va) -> pure (t, va)
  (t               , va) -> insert' cxt (pure (t, va))

-- | Insert fresh implicit applications until we hit a Pi with
--   a particular binder name.
insertUntilName :: Cxt -> Name -> IO (Tm, VTy) -> IO (Tm, VTy)
insertUntilName cxt name act = go =<< act where
  go (t, va) = case force va of
    va@(VPi x Impl a b) -> do
      if x == name then
        pure (t, va)
      else do
        m <- freshMeta cxt a
        let mv = eval (env cxt) m
        go (App t m Impl, b $$ mv)
    _ ->
      throwIO $ Error cxt $ NoNamedImplicitArg name

check :: Cxt -> P.Tm -> VTy -> IO Tm
check cxt t a = case (t, force a) of
  (P.SrcPos pos t, a) ->
    check (cxt {pos = coerce pos}) t a

  -- If the icitness of the lambda matches the Pi type, check as usual
  (P.Lam x ann i t, VPi x' i' a b) | either (\x -> x == x' && i' == Impl) (==i') i -> do
    case ann of
      Nothing  -> pure ()
      Just ann -> do {ann <- check cxt ann VU; unifyCatch cxt (eval (env cxt) ann) a}
    Lam x i' <$> check (bind cxt x a) t (b $$ VVar (lvl cxt))

  -- Otherwise if Pi is implicit, insert a new implicit lambda
  (t, VPi x Impl a b) -> do
    Lam x Impl <$> check (newBinder cxt x a) t (b $$ VVar (lvl cxt))

  (P.Pair t u, VSg x a b) -> do
    t <- check cxt t a
    u <- check cxt u (b $$ eval (env cxt) t)
    pure (Pair t u)

  (P.Let x a t u, a') -> do
    a <- check cxt a VU
    let ~va = eval (env cxt) a
    t <- check cxt t va
    let ~vt = eval (env cxt) t
    u <- check (define cxt x t vt a va) u a'
    pure (Let x a t u)

  (P.Hole, a) ->
    freshMeta cxt a

  (t, expected) -> do
    (t, inferred) <- insert cxt $ infer cxt t
    unifyCatch cxt expected inferred
    pure t

infer :: Cxt -> P.Tm -> IO (Tm, VTy)
infer cxt = \case
  P.SrcPos pos t ->
    infer (cxt {pos = coerce pos}) t

  P.Var x -> do
    case M.lookup x (srcNames cxt) of
      Just (x', a) -> pure (Var (lvl2Ix (lvl cxt) x'), a)
      Nothing      -> throwIO $ Error cxt $ NameNotInScope x

  P.Lam x ann (Right i) t -> do
    a <- case ann of
      Just ann -> eval (env cxt) <$> check cxt ann VU
      Nothing  -> eval (env cxt) <$> freshMeta cxt VU
    (t, b) <- insert cxt $ infer (bind cxt x a) t   -- t is extended context!  (b : Val)
    pure (Lam x i t, VPi x i a $ closeVal cxt b)

  P.Lam x ann Left{} t ->
    throwIO $ Error cxt $ InferNamedLam

  P.App t u i -> do

    -- choose implicit insertion
    (i, t, tty) <- case i of
      Left name -> do
        (t, tty) <- insertUntilName cxt name $ infer cxt t
        pure (Impl, t, tty)
      Right Impl -> do
        (t, tty) <- infer cxt t
        pure (Impl, t, tty)
      Right Expl -> do
        (t, tty) <- insert' cxt $ infer cxt t
        pure (Expl, t, tty)

    -- ensure that tty is Pi
    (a, b) <- case force tty of
      VPi x i' a b -> do
        unless (i == i') $
          throwIO $ Error cxt $ IcitMismatch i i'
        pure (a, b)
      tty -> do
        a <- eval (env cxt) <$> freshMeta cxt VU
        b <- Close (env cxt) <$> freshMeta (bind cxt "x" a) VU
        unifyCatch cxt tty (VPi "x" i a b)
        pure (a, b)

    u <- check cxt u a
    pure (App t u i, b $$ eval (env cxt) u)

  P.U ->
    pure (U, VU)

  P.Pi x i a b -> do
    a <- check cxt a VU
    b <- check (bind cxt x (eval (env cxt) a)) b VU
    pure (Pi x i a b, VU)

  P.Let x a t u -> do
    a <- check cxt a VU
    let ~va = eval (env cxt) a
    t <- check cxt t va
    let ~vt = eval (env cxt) t
    (u, b) <- infer (define cxt x t vt a va) u
    pure (Let x a t u, b)

  P.Sg x a b -> do
    a <- check cxt a VU
    b <- check (bind cxt x (eval (env cxt) a)) b VU
    pure (Sg x a b, VU)

  -- -- dependent Sg inference only for Var first proj
  -- P.Pair (P.Var x) u -> do
  --   (t, a) <- infer cxt t
  --   b <- Close (env cxt) <$> freshMeta (bind cxt "x" a) VU
  --   u <- check cxt u (b $$ eval (env cxt) t)
  --   pure (Pair t u, VSg "x" a b)

  -- only infer non-dependent Sg
  P.Pair t u -> do
    (t, a) <- infer cxt t
    (u, b) <- infer cxt u
    pure (Pair t u, VSg "_" a $ Fun $ \_ -> b)

  -- -- dependent Sg inference
  -- P.Pair t u -> do
  --   (t, a) <- infer cxt t
  --   b <- Close (env cxt) <$> freshMeta (bind cxt "x" a) VU
  --   u <- check cxt u (b $$ eval (env cxt) t)
  --   pure (Pair t u, VSg "x" a b)

  -- rarely works in practice:
  -- ?0 t = rhs     (t is not a bound var --> pattern problem)
  -- only way it can work:

  -- (x, u)     where x is a bound var
  -- b must be applied to a bound var

  -- λ (n : Nat). (n, replicate n true)
  --   replicate n true : Vec Bool n
  --   ?β n =? Vec Bool n     (OK)

  -- (with postponing could be sensible)


  P.Proj1 t -> do
    (t, tty) <- infer cxt t

    -- ensure that t has type (Sg x a b)
    (a, b) <- case force tty of
      VSg x a b ->
        pure (a, b)
      tty -> do
        a <- eval (env cxt) <$> freshMeta cxt VU
        b <- Close (env cxt) <$> freshMeta (bind cxt "x" a) VU
        unifyCatch cxt tty (VSg "x" a b)
        pure (a, b)

    pure (Proj1 t, a)

  P.Proj2 t -> do
    (t, tty) <- infer cxt t

    -- ensure tty = Sg x a b
    (a, b) <- case force tty of
      VSg x a b ->
        pure (a, b)
      tty -> do
        a <- eval (env cxt) <$> freshMeta cxt VU
        b <- Close (env cxt) <$> freshMeta (bind cxt "x" a) VU
        unifyCatch cxt tty (VSg "x" a b)
        pure (a, b)

    pure (Proj2 t, b $$ vProj1 (eval (env cxt) t))

  P.ProjField t x -> do
    (topT, topSg) <- infer cxt t
    let go :: Val -> VTy -> Int -> IO (Tm, VTy)
        go t sg n = case (force sg) of

          VSg x' a b
            | x == x'   -> pure (ProjField topT x n, a)
            | otherwise -> go (vProj2 t) (b $$ vProj1 t) (n + 1)

          -- I don't try anything, because I don't get any to compare my field name to!
          -- (with postponing: delay inference until type is known)
          _ ->
            throwIO $ Error cxt $ NoSuchField x (quote (lvl cxt) topSg)

    go (eval (env cxt) topT) topSg 0

  P.Hole -> do
    a <- eval (env cxt) <$> freshMeta cxt VU
    t <- freshMeta cxt a
    pure (t, a)
