# Herakles

Herakles is a tool for converting between various Nintendo Switch file formats.

## Status

Currently, it can only convert NSP files to the NX format, but support for the compressed archive format NXA is planned.

## Usage

You can download the latest release from [here](https://github.com/SamoZ256/herakles/releases/latest).

### Building

You need to have Zig 0.15.2 installed.

First, clone the repository.

```sh
git clone https://github.com/SamoZ256/herakles.git
cd herakles
```

Now run the project.

```sh
zig build run -- /path/to/input.nsp -k /path/to/prod.keys -o /path/to/output.nx
```

## Contributing

Pull requests are very welcome.
