// Our own JPEG decoder (Huffman coded baseline / extended sequential, 8 bit).
#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace tej {

// Decodes a JPEG into RGBA8 (alpha 255). Returns false and sets `err` on failure.
// Supported: gray and YCbCr (also RGB marked by an Adobe segment), any sampling
// up to 4x4 (4:4:4, 4:2:2, 4:2:0, 4:1:1 ...), restart markers, interleaved and
// separate scans, baseline, extended sequential and progressive (spectral selection
// and successive approximation), up to 16384 x 16384 and 64 million pixels.
// Not supported: arithmetic coded, lossless, 12 bit, CMYK.
bool decodeJpeg(const uint8_t* data, size_t size, int& w, int& h, std::vector<uint8_t>& rgba, std::string& err);

}  // namespace tej
