# @killbus/pdfium

**PDFium WASM build system** for the web platform.

> **Note**: This project's structure and build configuration are inspired by [@embedpdf/pdfium](https://github.com/embedpdf/embed-pdf-viewer).

## What is This?

This repository provides an automated build system that compiles Google's PDFium library to WebAssembly, packaged as an npm module. It uses a custom PDFium fork ([killbus/pdfium](https://github.com/killbus/pdfium)) and provides GitHub Actions workflows for automated building and releasing.

## Installation

### For Local Development (Unlocked)
To work locally without domain name constraints (runs on localhost/dev environments), install the development build from the private repository:

```bash
pnpm install github:killbus/pdfium-builder#release-dev
```

### For Production (Locked to pdfstart.com)
To install the production version of the package:

```bash
pnpm install github:killbus/pdfium-builder#release
```

### From Tarball

Download the tarball from [releases](https://github.com/killbus/pdfium-builder/releases), extract it, and install:

```bash
tar -xzf pdfium-wasm-*.tar.gz
npm install ./pdfium-wasm-*
```

## Package Contents

The built package includes:

- **WASM Binary**: `pdfium.wasm` - Compiled PDFium library
- **JavaScript Bundles**:
  - `index.js` - ESM entry point (Node.js/bundlers)
  - `index.browser.js` - Browser-optimized ESM
  - `index.cjs` - CommonJS entry point
- **TypeScript Declarations**: Full type definitions (`.d.ts`)
- **Source Maps**: For debugging

## Usage

```typescript
import { createPdfium } from '@killbus/pdfium';

const pdfium = await createPdfium();
// Use the PDFium WASM module
```

For API documentation, refer to the TypeScript declarations or the [PDFium documentation](https://pdfium.googlesource.com/pdfium/).

## Building from Source

### Prerequisites

- Node.js 22+
- pnpm
- Docker (for PDFium WASM build)

### Build PDFium WASM

The easiest way is to trigger the GitHub Actions workflow:

1. Go to **Actions** tab
2. Select **"PDFium WASM Build"**
3. Click **"Run workflow"**

Or build locally with Docker:

```bash
# Build development version (unlocked)
pnpm run wasm:build

# Build production version (domain locked to pdfstart.com)
PRODUCT_LOCK=1 pnpm run wasm:build
```

### Build npm Package

After building the WASM binary, run Rollup to bundle package targets:

```bash
pnpm install
pnpm run build
```

Output will be in `dist/`.


## GitHub Actions Workflows

### Build Workflow (`build.yml`)

Compiles PDFium WASM from source:
- Installs Emscripten SDK, depot_tools, and dependencies
- Builds PDFium with GN + Ninja
- Generates JavaScript bindings
- Uploads build artifacts

**Triggers**: Manual, push to main, pull requests

### Release Workflow (`release.yml`)

Automatically triggered after successful builds:
- Downloads build artifacts
- Builds npm package with Rollup
- Creates GitHub release with tarball
- Pushes to `release` branch for git-based installation

## Project Structure

```
pdfium-mod-wasm/
├── src/
│   ├── index.esm.ts          # ESM entry
│   ├── index.cjs.ts          # CommonJS entry
│   ├── base.ts               # Core PDFium wrapper
│   └── vendor/               # Generated bindings
├── pdfium-src/               # PDFium source (submodule)
├── scripts/
│   ├── build.sh              # PDFium build script
│   └── dev.sh                # Development script
├── build/
│   ├── patch/                # Build system patches
│   └── generate-*.mjs        # Code generation scripts
├── rollup.config.js          # Package bundler config
└── .github/workflows/
    ├── build.yml             # WASM build workflow
    └── release.yml           # Release automation
```

## Upstream Sources

- **PDFium Source**: [killbus/pdfium](https://github.com/killbus/pdfium) - Custom fork
- **Build Structure**: Inspired by [@embedpdf/pdfium](https://github.com/embedpdf/embed-pdf-viewer)
- **Upstream PDFium**: [Google PDFium](https://pdfium.googlesource.com/pdfium/)

## License

MIT

## Acknowledgments

- Google PDFium team for the PDF library
- [@embedpdf/pdfium](https://github.com/embedpdf/embed-pdf-viewer) for build system inspiration
