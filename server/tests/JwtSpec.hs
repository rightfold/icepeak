{-# LANGUAGE OverloadedStrings #-}
module JwtSpec (spec) where

--import qualified Data.Aeson as Aeson
import Data.Time.Clock (NominalDiffTime)
import Test.Hspec -- (Spec, describe, it, shouldBe, expectationFailure)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck.Instances ()
import qualified Web.JWT as JWT
import qualified Data.Map.Strict as Map
import qualified Data.Text.Encoding as Text

import JwtAuth
import AccessControl
import OrphanInstances ()

spec :: Spec
spec = do
  describe "JWT" $ do

    let testAccess = IcepeakClaim
          [ AuthPath ["foo"] [ModeRead]
          , AuthPath ["bar", "baz"] [ModeRead, ModeWrite]
          ]

    let emptyClaim = JWT.JWTClaimsSet
          { JWT.iss = Nothing
          , JWT.sub = Nothing
          , JWT.aud = Nothing
          , JWT.exp = Nothing
          , JWT.nbf = Nothing
          , JWT.iat = Nothing
          , JWT.jti = Nothing
          , JWT.unregisteredClaims = Map.empty
          }

    let testClaims = addIcepeakClaim testAccess emptyClaim

    let testSecret = JWT.binarySecret "2o8357cEuc2o835cmsoei"

    let now = 12512 :: NominalDiffTime

    it "should accept a valid token" $ do
      let tok = Text.encodeUtf8 $ JWT.encodeSigned JWT.HS256 testSecret testClaims
      extractClaim now testSecret tok `shouldBe` Right testAccess

    it "should reject an expired token" $ do
      let Just expDate = JWT.numericDate $ now - 10
          claims = testClaims { JWT.exp = Just expDate }
          expiredToken = Text.encodeUtf8 $ JWT.encodeSigned JWT.HS256 testSecret claims
      extractClaim now testSecret expiredToken `shouldBe` Left (VerificationError TokenExpired)

    it "should reject a token before its 'not before' date" $ do
      let Just nbfDate = JWT.numericDate $ now + 10
          claims = testClaims { JWT.nbf = Just nbfDate }
          nbfToken = Text.encodeUtf8 $ JWT.encodeSigned JWT.HS256 testSecret claims
      extractClaim now testSecret nbfToken `shouldBe` Left (VerificationError TokenUsedTooEarly)

    it "should reject a token with wrong secret" $ do
      let claims = testClaims
          nbfToken = Text.encodeUtf8 $ JWT.encodeSigned JWT.HS256 testSecret claims
          otherSecret = JWT.binarySecret "dfhwcmo845cm8e5"
      extractClaim now otherSecret nbfToken `shouldBe` Left (VerificationError TokenSignatureInvalid)

    prop "should correctly encode and decode token" $ \icepeakClaim ->
      let claims = addIcepeakClaim icepeakClaim emptyClaim
          encoded = Text.encodeUtf8 $ JWT.encodeSigned JWT.HS256 testSecret claims
          decoded = extractClaim now testSecret encoded
      in decoded == Right icepeakClaim
