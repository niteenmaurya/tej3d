// Our own PNG decoder (zlib inflate + filters). 8 and 16 bit, no interlace.
#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace tej {

// Decodes a PNG into RGBA8. Returns false and sets `err` on failure.
// Supported: gray, gray+alpha, RGB, RGBA, palette (with tRNS); bit depth 8
// or 16; not interlaced. Not supported: 1/2/4 bit, Adam7.
bool decodePng(const uint8_t* data, size_t size, int& w, int& h, std::vector<uint8_t>& rgba, std::string& err);

}  // namespace tej
