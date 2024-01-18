# Cubbit DS3 Sync

[![Xcode - Build and Analyze](https://github.com/marmos91/cubbit-ds3-sync/actions/workflows/build.yml/badge.svg)](https://github.com/marmos91/cubbit-ds3-sync/actions/workflows/build.yml)

<p align="center">
  <img alt="Cubbit" src="/Assets/Logo.png?raw=true" width="480">
</p>

## Welcome to Cubbit DS3 Sync!

This repository contains the source code of the Cubbit DS3 Sync application.

![App](/Assets/App.png)

## What is Cubbit DS3 Sync?

Cubbit DS3 Sync is a desktop application that synchronizes your files with your Cubbit DS3 account.

## How to build

To build the application please follow the steps below:

![Sync](/Assets/Tutorial1.png)

### Prerequisites

- MacOS 14 or later
- XCode 15.0 or later

### Build

To build the project you need to specify your own provisioning profile and signing certificate in the `Signing & Capabilities` tab of the project settings.
Please ensure that the App Group of the main app matches the one of the FileProvider

## Assets

To download the assets you need to use Git LFS

```
git lfs install
git lfs pull
```

## Next features

The next features we are going to support will be

- Support versioned buckets
- Support object locking
- Implement sync status in the tray menu
- Add support for thumbnails
- Add support for Zero Knowledge drives
- Support ACL public links

## How to contribute

You are free to contribute to the project by opening a pull request. Please make sure to follow the [contribution guidelines](CONTRIBUTING.md).

## License

The project is licensed under the [GPL](LICENSE).
