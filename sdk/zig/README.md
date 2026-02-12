# StarJay Zig SDK

In this folder there is a Zig SDK for the StarJay Fantasy Console.

It's structured in a similar way to Zig's `std` and it's expected you would `const starjay = @import("starjay");` just like you would `std`.

## Getting Started

The easiest way is to simply copy the template folder and fix all the `TODO`s. In your project folder:

```sh
git clone git@github.com:rj45/starjay-dev.git starjay
mkdir my_project
cp -a starjay/sdk/zig/template/* ./my_project/
```

If, instead, you want to make a new zig repository:

```sh
mkdir my_project
cd my_project
git init
zig init --minimal
```

With the public SDK, you can use `zig fetch --save` to add the SDK to `build.zig.zon` like this:

```sh
zig fetch --save git+https://github.com/rj45/starjay.git
```

However, this does not work for the private patron-only early-access repo. For that you need to clone into a parent folder:

```sh
git clone git@github.com:rj45/starjay-dev.git ../starjay
```

You will also want to go through the `template` folder in the same repo and copy whatever files look interesting. The `build.zig`, `src/start.s` and `src/linker.ld` would be the minimum I would recommend copying. This will get things building for the RISC-V RV32I core in StarJay.

In the template folder is a `just` file, a `task` file and a `make` file. Pick your favourite of the three and delete / don't copy the others. It has commands for building and running with the console.

## Contributions

I would very much appreciate any help making this SDK awesome! If you find yourself writing helpful functions or macros, please consider contributing those back to this SDK.

Please take some extra time to document public APIs and make sure the code is clear and readable. Please keep "macro magic" to a minimum except where it would be expected and idiomatic. Please prefer simplicity over cleverness.

### AI Use Policy

Please be careful with AI, prefer to use it as an advisor. 

There is AI generated code in this repo, but it has been well tested and refactored. I *might* accept AI generated contributions. However:

**I reserve the right to reject any contributions that look AI generated.**

This policy is there to prevent bots / low effort contributions from taking too much of my time. 

I might mistake your human written contributions as AI generated, and if so, I appologize in advance. If you feel you have been falsely accused of using AI, please contact me and I will look again.
