{-# LANGUAGE FlexibleContexts #-}

module Opaleye.Internal.Table where

import           Opaleye.Column (Column(Column))
import qualified Opaleye.QueryArr as QA
import qualified Opaleye.Internal.TableMaker as TM
import qualified Opaleye.Internal.Tag as Tag
import qualified Opaleye.Internal.PrimQuery as PQ
import qualified Opaleye.Internal.PackMap as PM
import qualified Opaleye.Internal.Values as V

import qualified Database.HaskellDB.PrimQuery as HPQ

import           Data.Profunctor (Profunctor, dimap, lmap)
import           Data.Profunctor.Product (ProductProfunctor, empty, (***!))
import qualified Data.Profunctor.Product as PP
import qualified Data.Profunctor.Product.Default as D
import           Control.Applicative (Applicative, pure, (<*>), liftA2)

data Table tablecols = Table String tablecols

makeTable :: D.Default TM.TableColumnMaker strings tablecolumns =>
             Table strings -> Table tablecolumns
makeTable = makeTableExplicit D.def

queryTable :: D.Default TM.ColumnMaker columns columns =>
              Table columns -> QA.Query columns
queryTable = queryTableExplicit D.def

makeTableExplicit :: TM.TableColumnMaker strings tablecolumns ->
                     Table strings -> Table tablecolumns
makeTableExplicit t (Table n strings) =
  Table n (TM.runTableColumnMaker t strings)

queryTableExplicit :: TM.ColumnMaker tablecolumns columns ->
                      Table tablecolumns -> QA.Query columns
queryTableExplicit cm table = QA.simpleQueryArr f where
  f ((), t0) = (retwires, primQ, Tag.next t0) where
    (retwires, primQ) = queryTable' cm table t0

queryTable' :: TM.ColumnMaker tablecolumns columns
            -> Table tablecolumns
            -> Tag.Tag
            -> (columns, PQ.PrimQuery)
queryTable' cm table tag = (primExprs, primQ) where
  (Table tableName tableCols) = table
  (primExprs, projcols) = runColumnMaker cm tag tableCols
  primQ :: PQ.PrimQuery
  primQ = PQ.BaseTable tableName projcols

runColumnMaker :: TM.ColumnMaker tablecolumns columns
                  -> Tag.Tag
                  -> tablecolumns
                  -> (columns, [(String, HPQ.PrimExpr)])
runColumnMaker cm tag tableCols = PM.run (TM.runColumnMaker cm f tableCols) where
  f = V.extractAttrPE mkName tag
  -- The non-AttrExpr PrimExprs are not created by 'makeTable' or a
  -- 'TableColumnMaker' so could only arise from an fmap (if we
  -- implemented a Functor instance) or a direct manipulation of the
  -- tablecols contained in the Table (which would be naughty)
  mkName pe i = (++ i) $ case pe of
    HPQ.AttrExpr columnName -> columnName
    _ -> "tablecolumn"

-- TODO: This should be the equivalent of a Control.Lens.Fold
data Writer columns a = Writer (PM.PackMap (HPQ.PrimExpr, String) () columns ())

data Writeable columns a = Writeable String (Writer columns a)

runWriter :: Writer columns columns' -> columns -> [(HPQ.PrimExpr, String)]
runWriter (Writer (PM.PackMap f)) columns = outColumns
  where extractColumns t = ([t], ())
        (outColumns, ()) = f extractColumns columns

required :: String -> Writer (Column a) (Column a)
required columnName =
  Writer (PM.PackMap (\f (Column primExpr) -> f (primExpr, columnName)))

optional :: String -> Writer (Maybe (Column a)) (Column a)
optional columnName =
  Writer (PM.PackMap (\f c -> case c of
                         Nothing -> pure ()
                         Just (Column primExpr) -> f (primExpr, columnName)))

-- {

-- Boilerplate instance definitions

instance Functor (Writer a) where
  fmap _ (Writer g) = Writer g

instance Applicative (Writer a) where
  pure x = Writer (fmap (const ()) (pure x))
  Writer f <*> Writer x = Writer (liftA2 (\_ _ -> ()) f x)

instance Profunctor Writer where
  dimap f _ (Writer h) = Writer (lmap f h)

instance ProductProfunctor Writer where
  empty = PP.defaultEmpty
  (***!) = PP.defaultProfunctorProduct

-- }