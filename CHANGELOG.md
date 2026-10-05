# Changelog

## [0.2.0](https://github.com/sgerrand/incident-io-rb/compare/v0.1.0...v0.2.0) (2026-10-05)


### ⚠ BREAKING CHANGES

* ScheduleEntryV2 no longer has a layer_id field.

### Features

* update generated code from the latest OpenAPI spec ([#11](https://github.com/sgerrand/incident-io-rb/issues/11)) ([e9c9df1](https://github.com/sgerrand/incident-io-rb/commit/e9c9df17b8d2a918447cbd0905a46c8c2c03862f))


### Bug Fixes

* **transport:** stop Net::HTTP re-sending timed out requests ([#9](https://github.com/sgerrand/incident-io-rb/issues/9)) ([599bc55](https://github.com/sgerrand/incident-io-rb/commit/599bc554df3139b43f01ff246eb87cfd6db12b03))


### Performance Improvements

* simplify the generator, resources, models and specs ([#5](https://github.com/sgerrand/incident-io-rb/issues/5)) ([e0c93f7](https://github.com/sgerrand/incident-io-rb/commit/e0c93f717aa21ff2e85064f32d09f2377acb6963))

## 0.1.0 (2026-09-27)


### Features

* add core HTTP client ([4ebfb9c](https://github.com/sgerrand/incident-io-rb/commit/4ebfb9c806f6f6fb3ad4fd263d5fde09305f9ade))
* add generated models and resources ([a740157](https://github.com/sgerrand/incident-io-rb/commit/a740157a6b85fd4df2239661a41b5d4cf1ce7ea3))
* add Rack middleware for incident.io webhooks ([a33d97d](https://github.com/sgerrand/incident-io-rb/commit/a33d97d07b85048b198949d8aca316e9fe6396cb))
* **core:** support generated resources in Resource and Page ([774b914](https://github.com/sgerrand/incident-io-rb/commit/774b914a74d93cbe72594345eff95c3a273d82a4))
* **generator:** generate models and resources from the OpenAPI spec ([f83b515](https://github.com/sgerrand/incident-io-rb/commit/f83b5159f6594e4b5ef3a7f2504a369d89d4e8bc))
* **generator:** generate webhook event and audit log maps ([d11e7c9](https://github.com/sgerrand/incident-io-rb/commit/d11e7c990d4081f4ca47f1e3746a886312fc2332))
* **generator:** write a manifest of generated operations ([ddb8925](https://github.com/sgerrand/incident-io-rb/commit/ddb892587d315b3d56803e33686cc977cd6bb06f))
* send nil as null for optional body arguments ([e71549d](https://github.com/sgerrand/incident-io-rb/commit/e71549d2dfafbddb812e7cf289e981942579e99b))
* send nil fields of models as null ([051ecde](https://github.com/sgerrand/incident-io-rb/commit/051ecde4d965f850d6d4d511e00759365c75b363))
* ship RBS type signatures ([f7e272f](https://github.com/sgerrand/incident-io-rb/commit/f7e272faa498b4ed9a84e5afb61f03f478ae31d3))
* verify and parse webhooks and audit log entries ([068cd0c](https://github.com/sgerrand/incident-io-rb/commit/068cd0c69e4d34911c6a8471e85ae165297af364))


### Bug Fixes

* **sig:** accept raw: in model constructors ([a9891e8](https://github.com/sgerrand/incident-io-rb/commit/a9891e85804dbec77a454df35c3def854dcce8c3))
