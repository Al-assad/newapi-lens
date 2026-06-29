# NewAPI Lens

[中文说明](README.zh-CN.md)

`NewAPI Lens` is a macOS desktop dashboard for `new-api` accounts. It helps you track balance, usage, model distribution, and spending trends in one place.

![NewAPI Lens Screenshot](docs/images/screenshot.png)

## Features

- Multi-account management for multiple `new-api` instances
- Overview dashboard for balance and daily, weekly, monthly usage
- Trend analysis by day, week, and month
- Period reports for usage and model distribution
- Menu bar entry for quick status access
- Auto refresh with configurable sync interval

## Install

After downloading the app, move it to `Applications` and launch it.

If macOS blocks the app because it is from an unidentified developer, run:

```bash
sudo xattr -rd com.apple.quarantine /Applications/newapi-lens.app
```

If you placed the app somewhere else, replace the path with the actual `.app` location.

## License

Licensed under the `GNU Affero General Public License v3.0`. See `LICENSE`.
