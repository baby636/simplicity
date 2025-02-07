/* This module defines operations used in the construction the environment ('txEnv') and some jets.
 */
#ifndef SIMPLICITY_PRIMITIVE_ELEMENTS_OPS_H
#define SIMPLICITY_PRIMITIVE_ELEMENTS_OPS_H

#include "../../sha256.h"
#include "primitive.h"

/* Compute an Element's entropy value from a prevoutpoint and a contract hash.
 * A reimplementation of GenerateAssetEntropy from Element's 'issuance.cpp'.
 *
 * Precondition: NULL != op;
 *               NULL != contract;
 */
sha256_midstate generateIssuanceEntropy(const outpoint* op, const sha256_midstate* contract);

/* Compute an Element's issuance Asset ID value from an entropy value.
 * A reimplementation of CalculateAsset from Element's 'issuance.cpp'.
 *
 * Precondition: NULL != entropy;
 */
sha256_midstate calculateAsset(const sha256_midstate* entropy);

/* Compute an Element's issuance Token ID value from an entropy value and an amount prefix.
 * A reimplementation of CalculateReissuanceToken from Element's 'issuance.cpp'.
 *
 * Precondition: NULL != entropy;
 */
sha256_midstate calculateToken(const sha256_midstate* entropy, confPrefix prefix);

#endif
