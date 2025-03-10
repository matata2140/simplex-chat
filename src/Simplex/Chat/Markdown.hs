{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use newtype instead of data" #-}

module Simplex.Chat.Markdown where

import Control.Applicative (optional, (<|>))
import Data.Aeson (ToJSON)
import qualified Data.Aeson as J
import Data.Attoparsec.Text (Parser)
import qualified Data.Attoparsec.Text as A
import Data.Char (isDigit)
import Data.Either (fromRight)
import Data.Functor (($>))
import Data.List (intercalate, foldl')
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import Data.Maybe (fromMaybe, isNothing)
import Data.Semigroup (sconcat)
import Data.String
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import GHC.Generics
import Simplex.Chat.Types
import Simplex.Chat.Types.Util
import Simplex.Messaging.Agent.Protocol (AConnectionRequestUri (..), ConnReqScheme (..), ConnReqUriData (..), ConnectionRequestUri (..), SMPQueue (..))
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (dropPrefix, enumJSON, fstToLower, sumTypeJSON)
import Simplex.Messaging.Protocol (ProtocolServer (..), SrvLoc (..))
import Simplex.Messaging.Util (safeDecodeUtf8)
import System.Console.ANSI.Types
import qualified Text.Email.Validate as Email

data Markdown = Markdown (Maybe Format) Text | Markdown :|: Markdown
  deriving (Eq, Show)

data Format
  = Bold
  | Italic
  | StrikeThrough
  | Snippet
  | Secret
  | Colored {color :: FormatColor}
  | Uri
  | SimplexLink {linkType :: SimplexLinkType, simplexUri :: Text, trustedUri :: Bool, smpHosts :: NonEmpty Text}
  | Email
  | Phone
  deriving (Eq, Show, Generic)

data SimplexLinkType = XLContact | XLInvitation | XLGroup
  deriving (Eq, Show, Generic)

instance ToJSON SimplexLinkType where
  toJSON = J.genericToJSON . enumJSON $ dropPrefix "XL"
  toEncoding = J.genericToEncoding . enumJSON $ dropPrefix "XL"

colored :: Color -> Format
colored = Colored . FormatColor

markdown :: Format -> Text -> Markdown
markdown = Markdown . Just

instance ToJSON Format where
  toJSON = J.genericToJSON $ sumTypeJSON fstToLower
  toEncoding = J.genericToEncoding $ sumTypeJSON fstToLower

instance Semigroup Markdown where
  m <> (Markdown _ "") = m
  (Markdown _ "") <> m = m
  m1@(Markdown f1 s1) <> m2@(Markdown f2 s2)
    | f1 == f2 = Markdown f1 $ s1 <> s2
    | otherwise = m1 :|: m2
  m1@(Markdown f1 s1) <> ms@(Markdown f2 s2 :|: m3)
    | f1 == f2 = Markdown f1 (s1 <> s2) :|: m3
    | otherwise = m1 :|: ms
  ms@(m1 :|: Markdown f2 s2) <> m3@(Markdown f3 s3)
    | f2 == f3 = m1 :|: Markdown f2 (s2 <> s3)
    | otherwise = ms :|: m3
  m1 <> m2 = m1 :|: m2

instance Monoid Markdown where mempty = unmarked ""

instance IsString Markdown where fromString = unmarked . T.pack

newtype FormatColor = FormatColor Color
  deriving (Eq, Show)

instance ToJSON FormatColor where
  toJSON (FormatColor c) = case c of
    Red -> "red"
    Green -> "green"
    Blue -> "blue"
    Yellow -> "yellow"
    Cyan -> "cyan"
    Magenta -> "magenta"
    Black -> "black"
    White -> "white"

data FormattedText = FormattedText {format :: Maybe Format, text :: Text}
  deriving (Eq, Show, Generic)

instance ToJSON FormattedText where
  toEncoding = J.genericToEncoding J.defaultOptions {J.omitNothingFields = True}

instance IsString FormattedText where
  fromString = FormattedText Nothing . T.pack

type MarkdownList = [FormattedText]

data ParsedMarkdown = ParsedMarkdown {formattedText :: Maybe MarkdownList}
  deriving (Generic)

instance ToJSON ParsedMarkdown where
  toJSON = J.genericToJSON J.defaultOptions {J.omitNothingFields = True}
  toEncoding = J.genericToEncoding J.defaultOptions {J.omitNothingFields = True}

unmarked :: Text -> Markdown
unmarked = Markdown Nothing

parseMaybeMarkdownList :: Text -> Maybe MarkdownList
parseMaybeMarkdownList s
  | all (isNothing . format) ml = Nothing
  | otherwise = Just . reverse $ foldl' acc [] ml
  where
    ml = intercalate ["\n"] . map (markdownToList . parseMarkdown) $ T.lines s
    acc [] m = [m] 
    acc ms@(FormattedText f t : ms') ft@(FormattedText f' t')
      | f == f' = FormattedText f (t <> t') : ms'
      | otherwise = ft : ms

parseMarkdownList :: Text -> MarkdownList
parseMarkdownList = markdownToList . parseMarkdown

markdownToList :: Markdown -> MarkdownList
markdownToList (Markdown f s) = [FormattedText f s]
markdownToList (m1 :|: m2) = markdownToList m1 <> markdownToList m2

parseMarkdown :: Text -> Markdown
parseMarkdown s = fromRight (unmarked s) $ A.parseOnly (markdownP <* A.endOfInput) s

markdownP :: Parser Markdown
markdownP = mconcat <$> A.many' fragmentP
  where
    fragmentP :: Parser Markdown
    fragmentP =
      A.peekChar >>= \case
        Just c -> case c of
          ' ' -> unmarked <$> A.takeWhile (== ' ')
          '+' -> phoneP <|> wordP
          '*' -> formattedP '*' Bold
          '_' -> formattedP '_' Italic
          '~' -> formattedP '~' StrikeThrough
          '`' -> formattedP '`' Snippet
          '#' -> A.char '#' *> secretP
          '!' -> coloredP <|> wordP
          _
            | isDigit c -> phoneP <|> wordP
            | otherwise -> wordP
        Nothing -> fail ""
    formattedP :: Char -> Format -> Parser Markdown
    formattedP c f = do
      s <- A.char c *> A.takeTill (== c)
      (A.char c $> md c f s) <|> noFormat (c `T.cons` s)
    md :: Char -> Format -> Text -> Markdown
    md c f s
      | T.null s || T.head s == ' ' || T.last s == ' ' =
        unmarked $ c `T.cons` s `T.snoc` c
      | otherwise = markdown f s
    secretP :: Parser Markdown
    secretP = secret <$> A.takeWhile (== '#') <*> A.takeTill (== '#') <*> A.takeWhile (== '#')
    secret :: Text -> Text -> Text -> Markdown
    secret b s a
      | T.null a || T.null s || T.head s == ' ' || T.last s == ' ' =
        unmarked $ '#' `T.cons` ss
      | otherwise = markdown Secret $ T.init ss
      where
        ss = b <> s <> a
    coloredP :: Parser Markdown
    coloredP = do
      clr <- A.char '!' *> colorP <* A.space
      s <- ((<>) <$> A.takeWhile1 (\c -> c /= ' ' && c /= '!') <*> A.takeTill (== '!')) <* A.char '!'
      if T.null s || T.last s == ' '
        then fail "not colored"
        else pure $ markdown (colored clr) s
    colorP =
      A.anyChar >>= \case
        'r' -> "ed" $> Red <|> pure Red
        'g' -> "reen" $> Green <|> pure Green
        'b' -> "lue" $> Blue <|> pure Blue
        'y' -> "ellow" $> Yellow <|> pure Yellow
        'c' -> "yan" $> Cyan <|> pure Cyan
        'm' -> "agenta" $> Magenta <|> pure Magenta
        '1' -> pure Red
        '2' -> pure Green
        '3' -> pure Blue
        '4' -> pure Yellow
        '5' -> pure Cyan
        '6' -> pure Magenta
        _ -> fail "not color"
    phoneP = do
      country <- optional $ T.cons <$> A.char '+' <*> A.takeWhile1 isDigit
      code <- optional $ conc4 <$> phoneSep <*> "(" <*> A.takeWhile1 isDigit <*> ")"
      segments <- mconcat <$> A.many' ((<>) <$> phoneSep <*> A.takeWhile1 isDigit)
      let s = fromMaybe "" country <> fromMaybe "" code <> segments
          len = T.length s
      if 7 <= len && len <= 22 then pure $ markdown Phone s else fail "not phone"
    conc4 s1 s2 s3 s4 = s1 <> s2 <> s3 <> s4
    phoneSep = " " <|> "-" <|> "." <|> ""
    wordP :: Parser Markdown
    wordP = wordMD <$> A.takeTill (== ' ')
    wordMD :: Text -> Markdown
    wordMD s
      | T.null s = unmarked s
      | isUri s = case strDecode $ encodeUtf8 s of
        Right cReq -> markdown (simplexUriFormat cReq) s
        _ -> markdown Uri s
      | isEmail s = markdown Email s
      | otherwise = unmarked s
    isUri s = T.length s >= 10 && any (`T.isPrefixOf` s) ["http://", "https://", "simplex:/"]
    isEmail s = T.any (== '@') s && Email.isValid (encodeUtf8 s)
    noFormat = pure . unmarked
    simplexUriFormat :: AConnectionRequestUri -> Format
    simplexUriFormat = \case
      ACR _ (CRContactUri crData) ->
        let uri = safeDecodeUtf8 . strEncode $ CRContactUri crData {crScheme = CRSSimplex}
         in SimplexLink (linkType' crData) uri (trustedUri' crData) $ uriHosts crData
      ACR _ (CRInvitationUri crData e2e) ->
        let uri = safeDecodeUtf8 . strEncode $ CRInvitationUri crData {crScheme = CRSSimplex} e2e
         in SimplexLink XLInvitation uri (trustedUri' crData) $ uriHosts crData
      where
        uriHosts ConnReqUriData {crSmpQueues} = L.map (safeDecodeUtf8 . strEncode) $ sconcat $ L.map (host . qServer) crSmpQueues
        trustedUri' ConnReqUriData {crScheme} = case crScheme of
          CRSSimplex -> True
          CRSAppServer (SrvLoc host _) -> host == "simplex.chat"
        linkType' ConnReqUriData {crClientData} = case crClientData >>= decodeJSON of
          Just (CRDataGroup _) -> XLGroup
          Nothing -> XLContact
