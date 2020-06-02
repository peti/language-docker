{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Language.Docker.Parser.Healthcheck
  ( parseHealthcheck,
  )
where

import Data.Maybe (listToMaybe)
import qualified Data.Text as T
import Data.Time.Clock (secondsToDiffTime)
import Language.Docker.Parser.Cmd (parseCmd)
import Language.Docker.Parser.Prelude
import Language.Docker.Syntax

data CheckFlag
  = FlagInterval Duration
  | FlagTimeout Duration
  | FlagStartPeriod Duration
  | FlagRetries Retries
  | CFlagInvalid (Text, Text)

parseHealthcheck :: Parser (Instruction Text)
parseHealthcheck = do
  reserved "HEALTHCHECK"
  Healthcheck <$> (fullCheck <|> noCheck)
  where
    noCheck = string "NONE" >> return NoCheck
    allFlags = do
      flags <- someFlags
      requiredWhitespace <?> "another flag"
      return flags
    someFlags = do
      x <- checkFlag
      cont <- try (requiredWhitespace >> lookAhead (string "--") >> return True) <|> return False
      if cont
        then do
          xs <- someFlags
          return (x : xs)
        else return [x]
    fullCheck = do
      flags <- allFlags <|> return []
      let intervals = [x | FlagInterval x <- flags]
      let timeouts = [x | FlagTimeout x <- flags]
      let startPeriods = [x | FlagStartPeriod x <- flags]
      let retriesD = [x | FlagRetries x <- flags]
      let invalid = [x | CFlagInvalid x <- flags]
      -- Let's do some validation on the flags
      case (invalid, intervals, timeouts, startPeriods, retriesD) of
        ((k, v) : _, _, _, _, _) -> unexpectedFlag k v
        (_, _ : _ : _, _, _, _) -> customError $ DuplicateFlagError "--interval"
        (_, _, _ : _ : _, _, _) -> customError $ DuplicateFlagError "--timeout"
        (_, _, _, _ : _ : _, _) -> customError $ DuplicateFlagError "--start-period"
        (_, _, _, _, _ : _ : _) -> customError $ DuplicateFlagError "--retries"
        _ -> do
          Cmd checkCommand <- parseCmd
          let interval = listToMaybe intervals
          let timeout = listToMaybe timeouts
          let startPeriod = listToMaybe startPeriods
          let retries = listToMaybe retriesD
          return $ Check CheckArgs {..}

checkFlag :: Parser CheckFlag
checkFlag =
  (FlagInterval <$> durationFlag "--interval=" <?> "--interval")
    <|> (FlagTimeout <$> durationFlag "--timeout=" <?> "--timeout")
    <|> (FlagStartPeriod <$> durationFlag "--start-period=" <?> "--start-period")
    <|> (FlagRetries <$> retriesFlag <?> "--retries")
    <|> (CFlagInvalid <$> anyFlag <?> "no flags")

durationFlag :: Text -> Parser Duration
durationFlag flagName = do
  void $ try (string flagName)
  scale <- natural
  unit <- char 's' <|> char 'm' <|> char 'h' <?> "either 's', 'm' or 'h' as the unit"
  case unit of
    's' -> return $ Duration (secondsToDiffTime scale)
    'm' -> return $ Duration (secondsToDiffTime (scale * 60))
    'h' -> return $ Duration (secondsToDiffTime (scale * 60 * 60))
    _ -> fail "only 's', 'm' or 'h' are allowed as the duration"

retriesFlag :: Parser Retries
retriesFlag = do
  void $ try (string "--retries=")
  n <- try natural <?> "the number of retries"
  return $ Retries (fromIntegral n)

anyFlag :: Parser (Text, Text)
anyFlag = do
  void $ string "--"
  name <- someUnless "the flag value" (== '=')
  void $ char '='
  val <- anyUnless (== ' ')
  return (T.append "--" name, val)

unexpectedFlag :: Text -> Text -> Parser a
unexpectedFlag name "" = customFailure $ NoValueFlagError (T.unpack name)
unexpectedFlag name _ = customFailure $ InvalidFlagError (T.unpack name)
