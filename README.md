# DS3 Drive

[![Xcode - Build and Analyze](https://github.com/marmos91/cubbit-ds3-sync/actions/workflows/build.yml/badge.svg)](https://github.com/marmos91/cubbit-ds3-sync/actions/workflows/build.yml)

<p align="center">
  <img alt="Cubbit" src="/Assets/Logo.png?raw=true" width="480">
</p>

## Welcome to DS3 Drive!

This repository contains the source code of the DS3 Drive application.

![App](/Assets/App.png)

## What is DS3 Drive?

DS3 Drive is a macOS desktop application that synchronizes your files with your Cubbit DS3 account. It uses Apple's File Provider framework to integrate with Finder, presenting remote S3 buckets as native macOS drives.

## How to build

![Sync](/Assets/Tutorial1.png)

### Prerequisites

- macOS 15 or later
- Xcode 16.0 or later

### Build

To build the project, open `DS3Drive.xcodeproj` in Xcode. You need to specify your own provisioning profile and signing certificate in the `Signing & Capabilities` tab.

Please ensure that the App Group (`group.io.cubbit.DS3Drive`) matches between the main app and the FileProvider extension.

## Assets

To download the assets you need to use Git LFS:

```
git lfs install
git lfs pull
```

## How to contribute

You are free to contribute to the project by opening a pull request. Please make sure to follow the [contribution guidelines](CONTRIBUTING.md).

## License

The project is licensed under the [GPL](LICENSE).
