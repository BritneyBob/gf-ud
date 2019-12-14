module GF2UD where

import UDConcepts
import GFConcepts
import UDAnnotations
import PGF hiding (CncLabels)

import qualified Data.Map as M
import Data.List
import Data.Char
import Data.Maybe

---------
-- to test

-- env <- getEnv

test env s = do
  let eng = actLanguage env
  let t = parseEng env s
  putStrLn "GF TREE:"
  putStrLn $ showExpr [] t
  
  let e0 = expr2annottree env eng t
  putStrLn "expr2annottree:"
  putStrLn $ prLinesRTree prAnnotNode e0
  
  let e = annotTree2labelledTree env eng e0
  putStrLn "annotTree2labelledTree:"
  putStrLn $ prLinesRTree prAnnotNode e
  
  let u0 = labelledTree2wordTree e
  putStrLn "labelledTree2wordTree:"
  putStrLn $ prLinesRTree prAnnotNode u0
  
  let u1 = applyNonlocalAnnotations env eng u0
  putStrLn "applyNonlocalAnnotations:"
  putStrLn $ prLinesRTree prAnnotNode u1
  
  let u2 = wordTree2udTree u1
  putStrLn "wordTree2udTree:"
  putStrLn $ prUDTree u2
  
  let u = udTree2sentence u2
  putStrLn "udTree2sentence:"
  putStrLn (prt u)
  putStrLn $ unlines (errors u)

  return u

-- richly annotated abstract tree, with extra nodes for each token
type AnnotTree = RTree AnnotNode

data AnnotNode = AnnotNode {
  anFun    :: CId,
  anCat    :: CId,
  anLabel  :: String, -- UD label coming from above
  anTarget :: Maybe String, -- intended label for syncat words not targeted to heads
  anToken  :: Maybe (Int,TokenInfo) -- token belonging to this node, with position number in sentence
  }
 deriving (Eq,Show)

---  anTokens :: [(Int,(String,String,String,[UDData],String))] -- tokens dominated by this node
data TokenInfo = TokenInfo {
  tokWord   :: String,
  tokLemma  :: String,
  tokPOS    :: String,
  tokMorpho :: [UDData]
  }
 deriving (Eq,Show)
 
prAnnotNode (AnnotNode f c l tg ts) =
  unwords $
    intersperse ";" ["@" ++ show i ++ ": " ++ prTokenInfo t | Just (i,t) <- [ts]] ++
    [maybe "" ('>':) tg] ++
    [showCId f,showCId c,l]

prTokenInfo (TokenInfo w l p m) = unwords [w,l,p,prt m]


---------------------------
-- the GF to UD pipeline
---------------------------

gf2ud :: UDEnv -> Language -> PGF.Tree -> UDSentence
gf2ud env lang =
    udTree2sentence
  . wordTree2udTree
  . labelledTree2wordTree
  . annotTree2labelledTree env lang
  . expr2annottree env lang
  

-- change node structure, create links to heads
wordTree2udTree :: AnnotTree -> UDTree
wordTree2udTree = annot UDIdRoot where
  annot udid tr@(RTree node trs) =
    let Just (position,tok) = anToken node
    in RTree
         (UDWord {
           udID     = UDIdInt position,
           udFORM   = tokWord tok,
           udLEMMA  = tokLemma tok,
           udUPOS   = tokPOS tok,
           udXPOS   = showCId (anCat node),
           udFEATS  = tokMorpho tok,
           udDEPREL = unHeadLabel (anLabel node),
           udHEAD   = udid,
           udDEPS   = "_",
           udMISC   = [UDData "FUN" [showCId (anFun node)]] ----
           })
         [annot (UDIdInt position) t | t <- trs]

-- apply operations that change the tree structure
applyNonlocalAnnotations :: UDEnv -> Language -> AnnotTree -> AnnotTree
applyNonlocalAnnotations env lang =
  lowerHead 
 where
   lowerHead tree@(RTree node trs) = RTree node (changes trs trs)
   changes bts ts = case ts of
       t:tt -> case anTarget (root t) of
         Just label -> case break (\t -> anLabel (root t) == label) bts of
           (bts1,h:bts2) -> changes (dropOut t (bts1 ++ [h{subtrees = t : subtrees h}] ++ bts2)) tt
           _ -> error $ "target not found among\n" ++ unlines (map (prAnnotNode . root) bts) --- t : changes bts tt
         _ -> changes bts tt
       [] -> bts
   dropOut t ts = filter (\u -> root t /= root u) ts

-- erase intermediate nodes, building a tree of words
labelledTree2wordTree :: AnnotTree -> AnnotTree
labelledTree2wordTree tr@(RTree node trs) =
  RTree
    node
    [labelledTree2wordTree t | t <- trs, isJust (anToken (root t))]

-- assign labels to functions and propagate them down to leaves
annotTree2labelledTree :: UDEnv -> Language -> AnnotTree -> AnnotTree
annotTree2labelledTree env lang =
    propagateLabels
  . addLabels root_Label
 where
   pgf = pgfGrammar env
   lookFun f = maybe defaultLabels id (M.lookup f (funLabels (absLabels env)))
   defaultLabels = head_Label:repeat dep_Label

   propagateLabels tr@(RTree node trs) = 
     RTree
       (followSpine node trs)
       [propagateLabels t | t <- concatMap dependentTrees trs]

   dependentTrees tr@(RTree node trs) =
     if (anLabel node /= head_Label)
     then [tr]
     else concatMap dependentTrees trs

   followSpine node trs = case trs of
     [] -> node
     _  -> case [(n,ts) | RTree n ts <- trs, anLabel n == head_Label] of
       [(n,ts)] -> followSpine n{anLabel = anLabel node} ts
       _ -> error $ unlines $ "ERROR: no unique head among" : map (prAnnotNode . root) trs

   -- labels added from fun annotations; for syncat words, from their lemma annotations
   --- relying on the order proper nodes + syncat word nodes
   addLabels label tr@(RTree node trs) = case lookFun (anFun node) of
       ls -> RTree
             (if anLabel node == dep_Label then node{anLabel = label} else node) -- don't change a predefined label
             [addLabels lab t | (lab,t) <- zip (ls++[anLabel (root t) | t <- trs, isJust (anToken (root t))]) trs]


-- decorate abstract tree with word information
expr2annottree :: UDEnv -> Language -> Tree -> AnnotTree
expr2annottree env lang tree =
    addWordsAndCats
  $ postOrderRTree
  $ expr2abstree
    tree
  
 where
   pgf = pgfGrammar env
-----   lookFun f = maybe []    id (M.lookup f (funLabels (absLabels env)))
   lookCat c = maybe x_POS id (M.lookup c (catLabels (absLabels env)))
   lookWord d w = maybe d id (M.lookup w (wordLabels (cncLabels env lang)))
   lookupLemma f w = (M.lookup (f,w) (lemmaLabels (cncLabels env lang)))              -- (fun,lemma) -> (label,targetLabel)
   lookMorpho d c i = maybe d id (M.lookup (c,i) (morphoLabels (cncLabels env lang))) -- i'th form of cat c
   lookupDiscont c i = (M.lookup (c,i) (discontLabels (cncLabels env lang)))          -- (cat,field) -> (pos,label,targetLabel)

   -- convert postorder GF to AnnotTree by adding words from bracketed linearization, categories and their UD pos tags, morpho indices
   addWordsAndCats (RTree (f,i) ts) = RTree node (map addWordsAndCats ts ++ toktrees)
    where
    
     node = AnnotNode {
       anFun = f,
       anCat = cat,
       anTarget = Nothing,
       anToken = Nothing,
       anLabel = dep_Label
       }

     toktrees = case (M.lookup i positions) of
       Just pws -> headsFirst $ map addLemma pws
       _ -> [] ---

     headsFirst ts = case partition (\t -> anLabel (root t) == dep_Label) ts of --- heads of discont
       (hs,nhs) -> hs ++ nhs

     (cat,isLeaf) = valCat (anFun node)

     addLemma (posit,(w,lind)) = case isLeaf of
         True -> case lookupDiscont cat lind of
           Just (pos,label,target) | label == head_Label ->   -- head of discontinuous constituent
             RTree node{
               anLabel = dep_Label,   -- to be redefined in annotTree2labelledTree.addLabels
               anToken = Just (posit,       
                 TokenInfo w
                 (mkLemma (anFun node))
                 (lookCat cat)
                 (lookMorpho (formData lind) (anCat node) lind)
                 )
               } []
           Just (pos,label,target) | label /= head_Label ->   -- discontinuous parts, such as verb particles and prepositions
             RTree node{
               anToken = Just (posit, TokenInfo w w pos []),  --- no morphology, works for particles and prepositions
               anLabel = label,
               anTarget = if target /= head_Label then Just target else Nothing
               } []
           _ -> RTree node{                           -- continuous categorematic words
                  anToken = Just (posit,              
                     TokenInfo w
                        (mkLemma (anFun node))
                        (lookCat cat)
                        (lookMorpho (formData lind) (anCat node) lind)
                        )
                       } []
         _ -> case lookWord (w,x_POS,[]) w of           -- syncat words
           (lemma,postag,morph) -> case lookupLemma f lemma of 
              Just (label,target) -> RTree node{
                 anLabel = label,
                 anTarget = if target /= head_Label then Just target else Nothing,
                 anToken = Just (posit, TokenInfo w lemma postag morph)
                 } []
              _ -> RTree node{
                     anToken = Just (posit, TokenInfo w lemma postag morph)
                     } []

     mkLemma f = unwords $ take 1 $ words $ linearize pgf lang (mkApp f []) --- if multiword, 1st word is lemma; e.g. "listen to"
   
     positions = bracketPositions $ case bracketedLinearize pgf lang tree of
       b:_ -> b
       _ -> error ("ERROR: no linearization for tree " ++ showExpr [] tree)
     
   valCat f = case functionType pgf f of
     Just typ -> case unType typ of
       (hs,cat,_) -> (cat, null hs)  -- valcat, whether atomic
     _ -> error ("ERROR: cannot find type of function " ++ showCId f)


-- for each in-order abs-node, find the words that the node dominates, with their position and morpho
bracketPositions :: BracketedString -> M.Map FId [(Int,(String,LIndex))]
bracketPositions = collect . numerate . pos 0 0

 where
 
   pos fid lindex bs = case bs of
     Bracket _ fi _ lind _ _ bss -> concatMap (pos fi lind) bss
     Leaf s -> [(fid,(w,lindex)) | w <- words s] -- separate words --- every word gets the same morpho index

   numerate fws = [(f,(p,wl)) | (p,(f,wl)) <- zip [1..] fws] -- assign a position number to every word
     
   collect fpws = M.fromListWith (++) [(f,[pwl])  | (f,pwl) <- fpws]  -- map abstree nodes to word information

