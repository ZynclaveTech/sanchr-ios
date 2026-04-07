#ifndef VYNC_OPRF_H
#define VYNC_OPRF_H

#include <stdint.h>

/// Blind a phone number for OPRF evaluation.
/// Writes 32 bytes to blinding_scalar_out and 32 bytes to blinded_point_out.
/// Returns 0 on success, -1 on error.
int32_t vync_oprf_blind(
    const char *phone,
    uint8_t *blinding_scalar_out,
    uint8_t *blinded_point_out
);

/// Unblind a server OPRF response using the original blinding scalar.
/// All buffers must be exactly 32 bytes.
/// Returns 0 on success, -1 on error.
int32_t vync_oprf_unblind(
    const uint8_t *server_response,
    const uint8_t *blinding_scalar,
    uint8_t *unblinded_out
);

#endif
