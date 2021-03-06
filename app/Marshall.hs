{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Marshall
  ( Config(..)
  , AlertCustomFields(..)
  , sfCaseFromHive
  , SfId(..)
  , Customer(..)
  ) where

import Lucid
import Prelude hiding (id)
import qualified Prelude

import Chronos (Time,Timespan(Timespan),Offset(..),SubsecondPrecision(..))
import Control.Monad (forM,forM_)
import Data.Aeson (FromJSON(..), toJSON, fromJSON, withObject, (.:))
import Data.ByteString.Short.Internal (ShortByteString(SBS))
import Data.Foldable (toList)
import Data.Function ((&))
import Data.Int (Int64)
import Data.Maybe (catMaybes)
import Data.Primitive (ByteArray(..))
import Data.Text (Text)
import Data.Text.Short (ShortText)
import Data.WideWord (Word128)
import Text.Read (readMaybe)
import TheHive.CortexUtils (Case(..))


import qualified Chronos
import qualified Chronos.Locale.English as EN
import qualified Data.Aeson as Json
import qualified Data.Aeson.Types as Json
import qualified Data.Bytes as Bytes
import qualified Data.List as List
import qualified Data.Scientific as Sci
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Short as TS
import qualified Data.Text.Short.Unsafe as TS
import qualified Data.Word.Base62 as Base62
import qualified Elasticsearch.Client as ES
import qualified Salesforce.Client as SF
import qualified TheHive.Client as Hive
import qualified TheHive.CortexUtils as Hive
import qualified Torsor
import qualified UUID


data Config = Config
  { hive :: Hive.Config
  , es :: ES.Config
  , sf :: SF.Config
  , allsight :: String
  }
instance FromJSON Config where
  parseJSON = withObject "Hive config" $ \v -> do
    hive <- do
      endpoint <- v .: "hive_endpoint"
      apikey <- v .: "hive_apikey"
      pure Hive.Config{endpoint,apikey}
    es <- do
      endpoint <- v .: "es_endpoint"
      username <- v .: "es_username"
      password <- v .: "es_password"
      pure ES.Config{endpoint,username,password}
    sf <- do
      endpoint <- v .: "sf_endpoint"
      clientId <- v .: "sf_client_id"
      clientSecret <- v .: "sf_client_secret"
      username <- v .: "sf_username"
      password <- v .: "sf_password"
      pure SF.Config{endpoint,clientId,clientSecret,username,password}
    allsight <- v .: "allsight_endpoint"
    pure Config{hive,allsight,es,sf}

-- data Data = Data
--   { hiveData :: Hive.Case
--   , customerData :: Customer
--   , notificationData :: Notification
--   , esData :: Json.Value
--   }

data AlertCustomFields = AlertCustomFields
  { customerId :: Int64
  , date :: String
  }
instance FromJSON AlertCustomFields where
  parseJSON = Json.withArray "Alert.customFields" $ \(toList -> fields) -> do
    adapted <- (Json.object <$>) $ forM fields $ withObject "customField" $ \v -> do
      name <- v .: "name"
      value <- v .: "value"
      pure (name :: Text, value :: Json.Value)
    flip (withObject "Alert.customFields") adapted $ \v -> do
      customerId <- (readMaybe <$> v .: "customer") >>= \case
        Nothing -> Json.parseFail "customerId not an integer"
        Just n -> pure n
      timestamp <- v .: "timestamp"
      pure AlertCustomFields
        { customerId
        , date = takeWhile (/= 'T') timestamp
        }

-- FIXME move the rule name cleaning functionality out of elastirec

sfCaseFromHive :: Customer -> Hive.Case Json.Value -> [Json.Value] -> Json.Value
sfCaseFromHive
    cust@Customer{sfAccountId}
    hiveCase@Case{hiveId,title,severity}
    esData
  = Json.object
    [ ("Subject", toJSON $ T.concat
        [ name cust <> " Security Alert: "
        , title
        ]
      )
    , ("Hive_Case__c", toJSON hiveLink)
    , ("Origin", "Layer 3 Alert")
    , ("AccountId", toJSON sfAccountId)
    , ("RecordTypeId", toJSON @Text "0124p000000V5n5AAC")
    , ("Security_Incident_Name__c", toJSON title)
    , ("Security__c", toJSON ruleId) -- TODO do we still want to use this id?
    , ("Security_Incident_Severity__c", toJSON severity)
    -- TODO: email subject?
    , ("Security_Alert_Attributes__c", toJSON $
        mkBody cust hiveCase esData title
      )
    , ("Security_Incident_UUID__c", toJSON traceId)
    , ("Description", toJSON $ aggregateDescription esData)
    ]
  where
  hiveLink = "https://hive.noc.layer3com.com/index.html#!/case/~" <> hiveId <> "/details"
  ruleId = delve (head esData) ["_source", "incident", "id"]
  traceId = delve (head esData) ["_source", "trace", "id"]

aggregateDescription :: [Json.Value] -> Text
aggregateDescription esData = T.intercalate "\n\n" $ List.nub . catMaybes $
  flip map esData $ \esDatum ->
    delve esDatum ["_source", "incident", "description"] >>= \case
      Json.String str -> Just str
      _ -> Nothing

mkBody :: Customer -> Hive.Case Json.Value -> [Json.Value] -> Text -> TL.Text
mkBody
    Customer{name,kibanaIndexPattern}
    hiveCase
    esData
    humanName = Lucid.renderText $ do
  h2_ $ toHtml $
    name <> " - Security Incident Report"
  p_ $ toHtml $
    Chronos.encode_YmdIMS_p EN.upper (SubsecondPrecisionFixed 0) Chronos.hyphen
      (Chronos.offsetDatetimeDatetime
        (Chronos.timeToOffsetDatetime (Offset (-300)) -- FIXME: customer offset
        (Hive.createdTime hiveCase)))
  p_ $ h2_ $ toHtml humanName
  p_ $ toHtml $ aggregateDescription esData
  let traceIds = incidentToEventId <$> esData
      times = incidentToTime <$> esData
      start = Timespan (-7_200_000_000_000) `Torsor.add` minimum times
      end = Timespan 7_200_000_000_000 `Torsor.add` maximum times
      url = kibanaTemplate kibanaIndexPattern (start, end) traceIds
  p_ $ a_ [ href_ $ TS.toText url ] "View Incidents in Kibana"
  -- TODO port the zero-case handling in
  -- case kibanaIndexPattern of
  --   0 -> p_ $ hyperlinkToRelevant allEventsUuid created traceIdentifier
  --   pat -> p_ $ hyperlinkToRelevant pat created traceIdentifier
  h3_ [] "Attributes:"
  forM_ esData $ \es -> do
    details_ [] $ do
      summary_ [] $ h4_ [] $ do
        maybeM_ (delve es ["_source", "trace", "id"]) $ \case
          Json.String str -> "Incident ID " <> toHtml str
          _ -> "Incident ID not known"
      dl_ [] $ do
        esAttr es ["destination", "addresses"]
        esAttr es ["destination", "ip"]
        esAttr es ["destination", "ips"]
        esAttr es ["destination", "ips_count"]
        esAttr es ["destination", "port"]
        esAttr es ["destination", "ports"]
        esAttr es ["destination", "zones"]
        esAttr es ["event", "action"]
        esAttr es ["event", "category"]
        esAttr es ["event", "created"]
        esAttr es ["event", "dataset"]
        esAttr es ["event", "end"]
        esAttr es ["event", "id"]
        esAttr es ["event", "kind"]
        esAttr es ["event", "module"]
        esAttr es ["event", "severity"]
        esAttr es ["event", "start"]
        esAttr es ["file", "md5s"]
        esAttr es ["host", "names"]
        esAttr es ["incident", "category"]
        esAttr es ["incident", "description"]
        esAttr es ["incident", "id"]
        esAttr es ["incident", "name"]
        esAttr es ["incident", "severity"]
        esAttr es ["mitre-attack-technique"]
        esAttr es ["network", "application"]
        esAttr es ["network", "applications"]
        esAttr es ["network", "direction"]
        esAttr es ["network", "directions"]
        esAttr es ["observer", "name"]
        esAttr es ["observer", "product"]
        esAttr es ["observer", "type"]
        esAttr es ["observer", "vendor"]
        esAttr es ["provenance", "event", "dataset"]
        esAttr es ["provenance", "event", "module"]
        esAttr es ["provenance", "observer", "product"]
        esAttr es ["provenance", "observer", "vendor"]
        esAttr es ["source", "addresses"]
        esAttr es ["source", "ip"]
        esAttr es ["source", "ips"]
        esAttr es ["source", "ips_count"]
        esAttr es ["source", "port"]
        esAttr es ["source", "ports"]
        esAttr es ["source", "user", "names"]
        esAttr es ["source", "user", "names_count"]
        esAttr es ["source", "zones"]
        esAttr es ["trace", "id"]
        esAttr es ["url", "domains"]
        esAttr es ["url", "domains_count"]
  -- case List.find (\(Notification{id}) -> id == ruleId) notifications of
  --   Nothing -> pure ()
  --   Just Notification{playbooks,suggestedActions,referenceLinks} -> p_ $ do
  --     when (PM.sizeofArray playbooks /= 0) $ do
  --       h3_ "Playbooks:"
  --       forM_ playbooks $ \playbook -> do
  --         p_ $ toHtml playbook
  --     when (PM.sizeofArray suggestedActions /= 0) $ do
  --       h3_ "Suggested Actions:"
  --       forM_ suggestedActions $ \suggestedAction -> do
  --         p_ $ toHtml suggestedAction
  --     when (PM.sizeofArray referenceLinks /= 0) $ do
  --       h3_ "References:"
  --       forM_ referenceLinks $ \referenceLink -> do
  --         p_ $ toHtml referenceLink
  where
  esAttr es path = do
    maybeM_ (delve es ("_source":path)) $ jsonAsHtml (T.intercalate "." path)

incidentToEventId :: Json.Value -> Word128
incidentToEventId inc = delve inc ["_source", "trace", "id"] & \case
  Nothing -> error "incident has no trace id"
  Just rawId -> Json.parseEither parseJSON rawId & \case
    Left err -> error $ "ill-typed incident trace id: " ++ err
    Right id -> Base62.decode128 (Bytes.fromAsciiString id) & \case
      Nothing -> error "malformed incident trace id"
      Just it -> it

incidentToTime :: Json.Value -> Time
incidentToTime inc = fromJSON <$> delve inc ["_source", "event", "created"]
  & \case
    Nothing -> error "incident has no event.created"
    Just (Json.Success str) ->
      T.encodeUtf8 str
      & Chronos.decodeUtf8_YmdHMS Chronos.w3c
      & \case
        Nothing -> error "malformed incident event.created"
        Just it -> Chronos.datetimeToTime it
    Just _ -> error $ "malformed incident trace id"

encodeKibanaUrlTime :: Time -> ShortText
encodeKibanaUrlTime t = case TS.fromByteString b of
  Nothing -> errorWithoutStackTrace "Allsight.Notification.encodeKibanaUrlTime: implementation mistake"
  Just r -> r
  where
  b = Chronos.encodeUtf8_YmdHMS (Chronos.SubsecondPrecisionFixed 3) Chronos.w3c
    $ Chronos.timeToDatetime
    $ t

kibanaTemplate :: Word128 -> (Time, Time) -> [Word128] -> ShortText
kibanaTemplate indexPattern (start, end) eventIds = TS.filter (/= ' ') $
  "https://dashboard.layer3com.com/s/allsight/app/kibana#\
    \/discover/10fd50f0-0735-11eb-9ff7-e9ef8c9367f7\
    \?_g=\
      \( filters: !()\
      \, refreshInterval: (pause: !t, value: 0)\
      \, time: \
        \( from: '" <> encodeKibanaUrlTime start <> "Z'\
        \, to: '" <> encodeKibanaUrlTime end <> "Z')\
      \)\
    \&_a=\
      \( filters: \
        \!(( '$state': (store: appState)\
          \, meta: \
            \( alias: !n\
            \, disabled: !f\
            \, index: e064c1b0-e616-11ea-9ff7-e9ef8c9367f7\
            \, key: event.ids\
            \, negate: !f\
            \, params: !('" <> TS.intercalate "','" encodedIds <> "')\
            \, type: phrases\
            \, value: '" <> TS.intercalate ",%20" encodedIds <> "'\
            \)\
          \, query: \
            \( bool: \
              \( minimum_should_match: 1\
              \, should: \
                \!("
                  <> (TS.intercalate "," $
                    flip map encodedIds $ \encId ->
                      "(match_phrase: (event.ids: '" <> encId <> "'))"
                  ) <>
                ")\
              \)\
            \)\
          \)\
        \)\
      \, index: '" <> (ba2st . UUID.encodeHyphenated) indexPattern <> "'\
      \, interval: auto\
      \)\
  \"
  where
  encodedIds :: [ShortText]
  encodedIds = (ba2st . Base62.encode128 ) <$> eventIds

instance FromJSON ShortText where
  parseJSON = (TS.fromText <$>) . Json.parseJSON


newtype SfId = SfId Text
instance FromJSON SfId where
  parseJSON = withObject "salesforce response" $ \v -> do
    SfId <$> v .: "id"


maybeM_ :: (Monad m) => Maybe a -> (a -> m b) -> m ()
maybeM_ Nothing _ = pure ()
maybeM_ (Just a) f = f a >> pure ()

jsonAsHtml :: Text -> Json.Value -> Html ()
jsonAsHtml label = helper withLabel
  where
  helper :: (Html () -> Html ()) -> Json.Value -> Html ()
  helper wrap = \case
    Json.String str -> wrap $ toHtml str
    Json.Number 0 -> pure ()
    Json.Number n -> case Sci.floatingOrInteger n of
      Right i -> wrap $ toHtml $ show @Int i
      Left r -> wrap $ toHtml $ show @Double r
    Json.Array (toList -> [x]) -> helper wrap x
    Json.Array xs -> wrap $ ul_ [] $ forM_ xs $ \x -> li_ [] $ helper Prelude.id x
    it -> error $ "can't render json: " ++ show it
  withLabel :: Html () -> Html ()
  withLabel content = do
    dt_ [] $ toHtml label
    dd_ [] content

delve :: Json.Value -> [Text] -> Maybe Json.Value
delve v0 path0 =Json.parseMaybe (loop path0) v0
  where
  loop [] = pure
  loop (prop:path) = withObject "" $ (loop path =<<) . (.: prop)


------

data Customer = Customer
  { id :: !Int64
  , sfAccountId :: !Text
  , name :: !Text
  -- , email :: !Text
  -- , severity :: !Int64
  -- , contacts :: !Contacts
  , kibanaIndexPattern :: {-# UNPACK #-} !Word128
  }

instance FromJSON Customer where
  parseJSON = Json.withObject "Customer" $ \v -> do
    id <- v .: "id"
    sfAccountId <- v .: "salesforce_account_id"
    name <- v .: "name"
    kibanaIndexPattern <- (v .: "kibana_index_pattern") >>= \str ->
      case UUID.decodeHyphenated (Bytes.fromShortByteString (TS.toShortByteString (TS.fromText str))) of
        Nothing -> fail "kibana_index_pattern should be a UUID"
        Just it -> pure it
    pure Customer{id,sfAccountId,name,kibanaIndexPattern}
    -- email <- v .: "email"
    -- severity <- v .: "severity"
    -- contacts <- v .: "contacts"

ba2st :: ByteArray -> ShortText
ba2st (ByteArray x) = TS.fromShortByteStringUnsafe (SBS x)
