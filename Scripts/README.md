# Source packaging

Create a clean source archive:

```sh
./Scripts/package-source.sh
```

Verify an archive in a fresh temporary directory:

```sh
./Scripts/verify-source-archive.sh ../Calcite-source.tar.gz
```

The packaging script disables macOS copyfile metadata and excludes build products, AppleDouble files, and Finder metadata.
