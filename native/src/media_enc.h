#pragma once
#include <cstdint>
#include <vector>

namespace tej {

// Pure C++17 zero-dependency PNG encoder (RGBA8, stored DEFLATE + CRC32 + Adler32).
bool encodePng(int width, int height, const uint8_t* rgba, std::vector<uint8_t>& out);

// Pure C++17 zero-dependency baseline JPEG encoder (4:4:4 YCbCr, 8x8 DCT, Annex K Huffman).
bool encodeJpeg(int width, int height, const uint8_t* rgba, int quality, std::vector<uint8_t>& out);

// Pure C++17 zero-dependency in-memory MJPEG-AVI 1.0 video recorder (RIFF/AVI + idx1).
struct VideoRecorder {
  int width = 0;
  int height = 0;
  int fps = 30;
  int quality = 80;
  bool active = false;
  std::vector<std::vector<uint8_t>> frames;

  void begin(int w, int h, int targetFps, int jpegQuality);
  bool addFrame(const uint8_t* rgba);
  bool finish(std::vector<uint8_t>& outAvi);
};

}  // namespace tej
