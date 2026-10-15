# Contributing

Thanks for your interest in BarDrop.

* **Report a bug:** open an [issue](https://github.com/zzuuuiii/BarDrop/issues/new/choose) with the “Report a bug” template. The macOS version, the BarDrop version (Settings → About BarDrop) and the steps that lead to the bug help a lot.
* **Ideas:** also via issues, using the “Suggest an idea” template.
* **Code:** fork the repository, make your change on its own branch and open a pull request against `main`. Before merging, GitHub Actions builds the app and runs all tests (`swift test`). Please cover new features with tests where possible.
* **Texts:** every text in the app exists in English and German, side by side in the code as `L("English", "Deutsch")`. Please add both when you add or change a text.

Contributions are licensed under the [GPL-3.0](../LICENSE), like BarDrop itself.

## Version numbers

`MAJOR.MINOR.PATCH`, as in [Semantic Versioning](https://semver.org):

* **MINOR** (1.29.0) for new features, **PATCH** (1.29.1) for fixes only, **MAJOR** for a fundamental change.
* Betas carry the number of the version they lead up to: `1.29.0-beta.1`, `1.29.0-beta.2`, … and finally `1.29.0` as the regular version.
* `Resources/VERSION` holds the full number; macOS gets the part without `-beta.N` as its short version.

## Releases

Every push to `main` builds BarDrop and publishes the version in `Resources/VERSION` as a **beta** (a GitHub pre-release). Only people who turned on Settings → About BarDrop → Beta versions get it.

A **regular** version is published by a commit whose message contains `[stable]`. Its release notes summarize all changes since the previous regular version. `[skip release]` builds and tests without publishing anything.
