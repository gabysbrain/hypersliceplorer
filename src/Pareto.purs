module Pareto where

import Prelude

import App.Data (AppData, AppDatum)
import Data.DataFrame (Query)
import Data.DataFrame as DF
import Data.Array as A
import Data.Foldable (class Foldable, sum, or, foldMap, any)
import Data.List as L
import Data.Maybe (Maybe(..), maybe, fromJust)
import Data.Ordering (invert)
import Data.StrMap as SM
import Data.Traversable (for)
import Partial.Unsafe (unsafePartial)

type ParetoSlab = {slab :: Int, data :: AppData}
type ParetoSlabs = DF.DataFrame ParetoSlab

paretoSet :: Query AppData AppData
paretoSet = paretoSubset id

paretoSubset :: (AppDatum -> AppDatum) -> Query AppData AppData
paretoSubset dimFilter = DF.init <$> _paretoSet dimFilter

pareto2dSlab :: Number -> String -> String -> Query AppData AppData
pareto2dSlab r d1 d2 = do
  isNonEmpty <- nonemptyDF
  paretoPts <- paretoSubset (filterDatum2D d1 d2)
  if isNonEmpty
     then do
       -- base the radius filter on the farthest point from the origin
       let distQ = DF.sort pointDistCmp
           farthestPt = rowOne $ DF.runQuery (distQ `DF.chain` DF.trim 1) paretoPts
           radiusFilter pt = maybe false ((>) (r*r)) $ pointSqDist farthestPt pt
       pure $ DF.runQuery (DF.filter radiusFilter) paretoPts
     else pure $ DF.init L.Nil

pareto2dSlabs :: Number -> String -> String -> Query AppData ParetoSlabs
pareto2dSlabs r d1 d2 = do
  slabs <- _pareto2dSlabs r d1 d2
  let slabIds = L.range 1 (L.length slabs)
  pure $ DF.init $ L.zipWith (\i d -> {slab: i, data: d}) slabIds slabs

_pareto2dSlabs :: Number -> String -> String -> Query AppData (L.List AppData)
_pareto2dSlabs r d1 d2 = do
  slab <- pareto2dSlab r d1 d2
  if DF.rows slab > 0
     then cons slab <$> ((cleanEntries slab) `DF.chain` (_pareto2dSlabs r d1 d2))
     else pure L.Nil

-- FIXME: not sure why I need this separate function but ok...
-- TODO: figure out the better way to handle the monad wrt 
--       why I can't use whileM. Maybe switch Query to a state Monad...
_paretoSet :: (AppDatum -> AppDatum) -> Query AppData (L.List AppDatum)
_paretoSet dimFilter = do
  nonempty <- nonemptyDF
  if nonempty
     then do
       -- TODO: put all dim filtering in here and remove it from the 
       --       processing functions
       p <- rowOne <$> DF.sort (paretoOrder dimFilter) `DF.chain` DF.trim 1 
       --DF.filter (not <<< comparable (rowOne p))
       --fds <- DF.filter (pointFilter dimFilter p)
       cons p <$> (DF.filter (pointFilter dimFilter p) `DF.chain` _paretoSet dimFilter)
       --pure $ p L.: (DF.runQuery (_paretoSet dimFilter) fds)
     else pure L.Nil

paretoOrder :: (AppDatum -> AppDatum) -> AppDatum -> AppDatum -> Ordering
paretoOrder dimFilter p1 p2 = invert $
  if p1' < p2' then LT
  else if p1' > p2' then GT
  else EQ
  where 
  p1' = sum $ SM.values (dimFilter p1).point
  p2' = sum $ SM.values (dimFilter p2).point

-- determine if p1 is comparable to p2
-- i.e. at least one factor of p2 >= p1
comparable :: AppDatum -> AppDatum -> Boolean
comparable {point:p1} {point:p2} = maybe false or $ 
                   for (A.union (SM.keys p1) (SM.keys p2)) \k -> do
  v1 <- SM.lookup k p1
  v2 <- SM.lookup k p2
  pure $ v1 <= v2

pointSqDist :: AppDatum -> AppDatum -> Maybe Number
pointSqDist {point:p1} {point:p2} = 
  sum <$> for (A.union (SM.keys p1) (SM.keys p2)) \k -> do
    v1 <- SM.lookup k p1
    v2 <- SM.lookup k p2
    pure $ (v1-v2)*(v1-v2)

pointDistCmp :: AppDatum -> AppDatum -> Ordering
pointDistCmp {point:p1} {point:p2} = invert $ compare d1 d2
  where 
  d1 = sum $ map (\x -> x*x) $ SM.values p1
  d2 = sum $ map (\x -> x*x) $ SM.values p2

pointFilter :: (AppDatum -> AppDatum) -> AppDatum -> AppDatum -> Boolean
pointFilter dimFilter p1 p2 = (p1.rowId /= p2.rowId) && (comparable p1' p2')
  where
  p1' = dimFilter p1
  p2' = dimFilter p2

nonemptyDF :: Query AppData Boolean
nonemptyDF = do
  rs <- A.length <$> DF.summarize id
  pure $ rs /= 0

rowOne :: AppData -> AppDatum
rowOne = unsafePartial $ fromJust <<< L.head <<< foldMap L.singleton
--rowOne = fromMaybe SM.empty <<< L.head <<< foldMap L.singleton

filterDatum2D :: String -> String -> AppDatum -> AppDatum
filterDatum2D d1 d2 datum = datum {point=SM.fold hasKeys SM.empty datum.point}
  where
  hasKeys m k v = if k == d1 || k == d2
                   then SM.insert k v m
                   else m

cleanEntries :: AppData -> Query AppData AppData
cleanEntries es = DF.filter (flip (notElemBy cmp_) es)
  where
  cmp_ d1 d2 = d1.rowId == d2.rowId

notElemBy :: forall a f. Foldable f => (a -> a -> Boolean) -> a -> f a -> Boolean
notElemBy f x = not <<< (elemBy f x)

elemBy :: forall a f. Foldable f => (a -> a -> Boolean) -> a -> f a -> Boolean
elemBy f = any <<< f

cons :: forall a. a -> L.List a -> L.List a
cons x xs = x L.: xs

