/* The stb single-header implementations the provider's launcher-icon
   staging needs (tools/package/icon.zig): stb_image (PNG decode) and
   stb_image_write (PNG encode), both in no-stdio mode — the icon code feeds
   bytes in and collects them out itself.

   Vendored verbatim from labelle-cli `src/cli/stb_image.h` (v2.30) and
   `src/cli/stb_image_write.h` (v1.16) at development 23aa180, with the same
   encoder defaults, so the mipmaps are byte-identical to the ones the CLI's
   packager wrote. Decode is PNG-only: the icon is always a PNG. */

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include "stb_image_write.h"
