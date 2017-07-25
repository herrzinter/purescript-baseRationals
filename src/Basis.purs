
module Basis where


import PreciseFloat
import Prelude

import Data.Int as Int
import Data.BigInt as BI
import Data.String as String
import Data.Array as Array
import Data.List as List

import Data.EuclideanRing (class EuclideanRing)
import Data.BigInt (BigInt(..), fromString, pow, toNumber, toString, abs)
import Data.Ratio (Ratio(..))
import Data.Foldable (any, foldl)
import Data.List (List(..), length, init, take, drop, filter, elemIndex, index,
                  reverse, (:), (..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Either (Either(..))
import Control.Error.Util (note)
import Control.Monad.Rec.Class (Step(..), tailRecM3)


type BasisFunctions =
    {   isFinit     :: Int -> Ratio BigInt -> Maybe Boolean
    ,   fromString  :: Int -> String       -> Either String (Ratio BigInt)
    ,   toString    :: Int -> Ratio BigInt -> Either String String
    }

-- Basis smaller equal one do not make sense
isValidDigitArray :: Array Char -> Boolean
isValidDigitArray digitArray = Array.length digitArray >= 2

functionsFromDigitArray :: Array Char -> Maybe BasisFunctions
functionsFromDigitArray digitsArray
    | not $ isValidDigitArray digitsArray = Nothing
    | otherwise                           = Just {isFinit, fromString, toString}
  where
    digits = List.fromFoldable digitsArray
    basisMax = length digits

    -- The prime factorizations of all possible basis of a list of digits
    -- is used for several calculations eg. checking, if a fraction has a
    -- finit representation in a certain basis. As it is expensive to
    -- calculate primes and prime factorizations their are calculated for
    -- one module

    primeFactorsList :: List (List BigInt)
    primeFactorsList = do
        basis <- 2 .. basisMax
        let factorization = factorize primes basis
        pure $ map BI.fromInt factorization.factors
      where
        primes = calculatePrimes basisMax

    getPrimeFactors basis = primeFactorsList `index` (basis - 2)

    isFinit basis (Ratio _ denominator)
        | basis > basisMax = Nothing
        -- If the denominator can be complete factorized by the primefactors
        -- of the current basis, the non-fractional rendering of the
        -- rational is finit
        | otherwise = Just (foldl factorizeMany denominator primeFactors == one)
          where
            primeFactors = fromMaybe Nil (getPrimeFactors basis)

            factorizeMany number factor
                | number `mod` factor == zero = factorizeMany (number / factor) factor
                | otherwise                   = number


    fromString :: Int -> String -> Either String (Ratio BigInt)
    fromString basis string
        | 1 < basis && basis <= basisMax =
            let cs = List.fromFoldable $ String.toCharArray $ string
            in  fromCharList digits basis cs
        | otherwise = Left $
            "Basis not between 1 and " <> show basisMax

    toString :: Int -> Ratio BigInt -> Either String String
    toString basis ratio
        | basis <= basisMax = do
            cs <- toCharList digits basis ratio
            pure $ String.fromCharArray $ List.toUnfoldable $ cs
        | otherwise = Left $
            "Basis " <> show basis <> " exceeds maximum basis" <> show basisMax

-- Match possible negative sign, parse remaining chars and negate result
fromCharList :: List Char -> Int -> List Char -> Either String (Ratio BigInt)
fromCharList digits basis ('-' : cs) = do
    ratio <- fromCharList digits basis cs
    pure (-ratio)
fromCharList digits basis cs = do
    let basisBI = BI.fromInt basis
    let point = case '.' `elemIndex` cs of
            Just i  -> i + one
            Nothing -> length cs
    let shift = BI.fromInt (length cs - point)
    let cs' = filter (\c -> c /= '.') cs

    numerator <- parseDigits digits basisBI cs'

    pure $ Ratio numerator (basisBI `pow` shift)

toCharList :: List Char -> Int -> Ratio BigInt -> Either String (List Char)
toCharList digits basis ratio = do
    let basisBI = BI.fromInt basis
    -- Seperate the *propper* part of the fraction and the
    -- *remainder*
    let {propper, remainder} = propperize ratio

    -- Calculate *pre* and *post* radix chars
    pre <- preFromPropper digits basisBI propper
    post <- postFromRemainder digits basisBI (fromRatio remainder)
    let cs = pre <> (Cons '.' Nil) <> post

    -- TODO Alter chars for display
    note "String is empty" (cleanString cs)

cleanString :: List Char -> Maybe (List Char)
cleanString cs = do
    p <- '.' `elemIndex` cs
    let len = length cs

    case Nothing of
        _ | p == zero && len == one -> Just $ Cons '0' Nil
          | p == zero               -> Just $ '0' : cs
          | p == len - one          -> init cs
          | otherwise               -> Just cs

parseDigits
    :: List Char            -- Digits
    -> BigInt               -- Basis
    -> List Char            -- Input characters
    -> Either String BigInt -- Error or parsed number
parseDigits digits basis cs0 = loop (reverse cs0) zero zero
  where
    loop (c : cs) accumulator position  = do
        digitValue <- note
            ("Failed to lookup " <> show c <> " in digits " <> show digits)
            (c `elemIndex` digits)

        let positionValue = basis `pow` position
        let delta         = (BI.fromInt digitValue) * positionValue

        loop cs (accumulator + delta) (position + one)
    loop  _       accumulator _         = pure accumulator

preFromPropper
    :: List Char -- Digits
    -> BigInt    -- Basis
    -> BigInt    -- Propper
    -> Either String (List Char)
preFromPropper digits basis propper = loop Nil propper
  where
    loop cs dividend
      | dividend >= one = do
          -- Calculate quotient and remainder of division by
          -- basis
          let remainder = dividend `mod` basis
          let quotient = (dividend - remainder) / basis
          -- Get Corresponding digit character
          c <- lookupDigits digits remainder

          loop (c : cs) quotient
      | otherwise = Right cs

postFromRemainder
    :: List Char                  -- Digits
    -> BigInt                     -- Base
    -> PreciseFloat               -- Remainder
    -> Either String (List Char)  -- Post radix string
postFromRemainder digits basis pf0 = tailRecM3 loop Nil Nil (pf0 `scale` basis)
  where
    loop
        :: List PreciseFloat  -- Intermediate values to check for reccurence
        -> List Char          -- Accumulator for the output characters
        -> PreciseFloat       -- Intermediate value
        -> Either String _
    loop pfs cs pf@(PreciseFloat pfr)
        | toDigitsBI pf /= zero = case pf `elemIndex` pfs  of
            Nothing -> do
                -- Calculate index *i* and lookup corresponding char *c*
                let n = pfr.shift - pfr.infinitLength
                let iBI = pfr.finit `stripNDigitsOnTheRight` n
                c <- lookupDigits digits iBI
                let finit' = pfr.finit - iBI `appendNZerosOnTheRight` n

                pure $ Loop
                    { a: (pf : pfs)
                    , b: (c : cs)
                    , c: (PreciseFloat pfr {finit = finit'}) `scale` basis
                    }
            -- Recurrence -> return with parantheses marking recurrence
            Just i ->
                let i' = length pfs - i - one
                    cs' = reverse cs
                    finitChars = take i' cs'
                    infinitChars = ('[' : Nil) <> (drop i' cs') <> (']' : Nil)
                in  pure $ Done (finitChars <> infinitChars)
        | otherwise = pure $ Done $ reverse cs

lookupDigits :: List Char -> BigInt -> Either String Char
lookupDigits digits iBI = do
    i <- note "Failed to convert numbers" (Int.fromNumber $ toNumber iBI)
    c <- note "Failed to lookup character" (digits `index` i)
    pure c

-- | Factorize a member of an euclidian ring by a list of factors
factorize
    :: forall n . EuclideanRing n => Eq n =>
    List n -> n -> {factors :: List n, remainder :: n}
factorize factors number
    | number /= zero =
        let factorizeRecursive (f : fs) factorization
                | factorization.remainder `mod` f == zero =
                    factorizeRecursive (f : fs) factorization'
                      where
                        factorization' =
                          { factors: (f : factorization.factors)
                          , remainder: (factorization.remainder / f)
                          }
                | otherwise =
                factorizeRecursive fs factorization
            factorizeRecursive _ factorization = factorization
        in factorizeRecursive factors {factors : Nil, remainder : number}
    | otherwise = {factors : Nil, remainder : zero}


-- | Calculate all prime numbers between two and the maximum
calculatePrimes
    :: forall n . EuclideanRing n => Eq n => Ord n
    => n -> List n
calculatePrimes maximum
    | maximum > one =
        let calculatePrimes' number primes
                | number > maximum = primes
                | any (\p -> number `mod` p == zero) primes =
                    calculatePrimes' (number + one) primes
                | otherwise =
                    calculatePrimes' (number + one) (number : primes)
        in calculatePrimes' (one + one) Nil
    | otherwise = Nil
