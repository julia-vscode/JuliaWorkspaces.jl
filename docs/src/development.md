# Development

## Compiling the documentation locally
When you are working on the documentation you want to compile it locally to check for syntax errors and to check if it looks right.

To do that, it is suggested to install the package `LiveServer` globally:
```bash
julia -e 'using Pkg; Pkg.add("LiveServer")'
```

Then, you can use the following script to build the documentation and to launch a documentation server at the URL [http://localhost:8000](http://localhost:8000):
```bash
#!/bin/bash -eu
# This script is used to serve the documentation locally.

if [[ $(basename $(pwd)) == "bin" ]]; then
    cd ..
fi
julia --project="./docs/." -e 'using Pkg; Pkg.instantiate()'
LANG=en_US julia --project="./docs/." -e 'include("docs/make.jl"); using LiveServer; servedocs()'
```
I suggest to save this script under the name `doc` in the `bin` folder, which you might have to create first.
You can then build the documentation with the command:
```
./bin/doc
```
On Linux, you have to make it executable first: `chmod +x ./bin/doc`.