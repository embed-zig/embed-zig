# oapi-codegen Spec List

Source repository: [https://github.com/oapi-codegen/oapi-codegen](https://github.com/oapi-codegen/oapi-codegen)

Selection rule: files under `internal/test/` that parse as YAML/JSON and whose root document contains `openapi` or `swagger`. Non-spec files such as `config.yaml` and `cfg.yaml` are intentionally excluded.

Total detected OpenAPI documents: **72**

| Fixture Dir | OpenAPI | Title | Source |
| --- | --- | --- | --- |
| `all_of` | 3.0.1 | Tests AllOf composition | [`all_of/openapi.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/all_of/openapi.yaml) |
| `any_of/codegen/inline` | 3.0.0 | Cats, Dogs and Rats API | [`any_of/codegen/inline/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/any_of/codegen/inline/spec.yaml) |
| `any_of/codegen/ref_schema` | 3.0.0 | Cats, Dogs and Rats API | [`any_of/codegen/ref_schema/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/any_of/codegen/ref_schema/spec.yaml) |
| `any_of/param` | 3.0.0 | AnyOf parameter | [`any_of/param/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/any_of/param/spec.yaml) |
| `client` | 3.0.1 | Test Server | [`client/client.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/client/client.yaml) |
| `compatibility/preserve-original-operation-id-casing-in-embedded-spec` | 3.0.0 | my spec | [`compatibility/preserve-original-operation-id-casing-in-embedded-spec/api.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/compatibility/preserve-original-operation-id-casing-in-embedded-spec/api.yaml) |
| `components/components` | 3.0.1 | Test Server | [`components/components.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/components/components.yaml) |
| `cookies` | 3.0.1 | Cookie parameters | [`cookies/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/cookies/spec.yaml) |
| `externalref/petstore` | 3.0.2 | Swagger Petstore - OpenAPI 3.0 | [`externalref/petstore/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/externalref/petstore/spec.yaml) |
| `externalref` | 3.0.0 |  | [`externalref/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/externalref/spec.yaml) |
| `filter` | 3.0.1 | Test Server | [`filter/server.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/filter/server.yaml) |
| `issue-1039` | 3.0.1 | example | [`issues/issue-1039/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1039/spec.yaml) |
| `issue-1087/deps/my-deps` | 3.0.3 | Models | [`issues/issue-1087/deps/my-deps.json`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1087/deps/my-deps.json) |
| `issue-1087` | 3.0.3 | test | [`issues/issue-1087/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1087/spec.yaml) |
| `issue-1093/child.api` | 3.0.0 | child | [`issues/issue-1093/child.api.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1093/child.api.yaml) |
| `issue-1093/parent.api` | 3.0.0 | parent | [`issues/issue-1093/parent.api.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1093/parent.api.yaml) |
| `issue-1127` | 3.0.1 | api | [`issues/issue-1127/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1127/spec.yaml) |
| `issue-1168` | 3.0.3 | Test | [`issues/issue-1168/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1168/spec.yaml) |
| `issue-1180` | 3.0.1 | Test Server | [`issues/issue-1180/issue.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1180/issue.yaml) |
| `issue-1182/pkg1` | 3.0.1 | Test Server | [`issues/issue-1182/pkg1.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1182/pkg1.yaml) |
| `issue-1182/pkg2` | 3.0.1 | Test Server | [`issues/issue-1182/pkg2.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1182/pkg2.yaml) |
| `issue-1189/issue1189` | 3.0.0 |  | [`issues/issue-1189/issue1189.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1189/issue1189.yaml) |
| `issue-1208-1209/issue-multi-json` | 3.0.0 |  | [`issues/issue-1208-1209/issue-multi-json.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1208-1209/issue-multi-json.yaml) |
| `issue-1212/pkg1` | 3.0.0 |  | [`issues/issue-1212/pkg1.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1212/pkg1.yaml) |
| `issue-1212/pkg2` | 3.0.1 |  | [`issues/issue-1212/pkg2.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1212/pkg2.yaml) |
| `issue-1219` | 3.0.1 |  | [`issues/issue-1219/issue.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1219/issue.yaml) |
| `issue-1298/issue1298` | 3.0.1 |  | [`issues/issue-1298/issue1298.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1298/issue1298.yaml) |
| `issue-1373` | 3.0.2 | example | [`issues/issue-1373/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1373/spec.yaml) |
| `issue-1378/bionicle` | 3.0.1 | Test | [`issues/issue-1378/bionicle.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1378/bionicle.yaml) |
| `issue-1378/common` | 3.0.1 | Test | [`issues/issue-1378/common.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1378/common.yaml) |
| `issue-1378/foo-service` | 3.0.1 | Test | [`issues/issue-1378/foo-service.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1378/foo-service.yaml) |
| `issue-1397` | 3.0.1 |  | [`issues/issue-1397/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1397/spec.yaml) |
| `issue-1529/strict-echo` | 3.0.1 |  | [`issues/issue-1529/strict-echo/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1529/strict-echo/spec.yaml) |
| `issue-1529/strict-fiber` | 3.0.1 |  | [`issues/issue-1529/strict-fiber/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1529/strict-fiber/spec.yaml) |
| `issue-1529/strict-iris` | 3.0.1 |  | [`issues/issue-1529/strict-iris/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1529/strict-iris/spec.yaml) |
| `issue-1676` | 3.0.0 | Issue 1676 | [`issues/issue-1676/api.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1676/api.yaml) |
| `issue-1914` | 3.0.3 |  | [`issues/issue-1914/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1914/spec.yaml) |
| `issue-1963` | 3.0.3 | issue-1963 | [`issues/issue-1963/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-1963/spec.yaml) |
| `issue-2031` | 3.0.0 | Issue 2031 | [`issues/issue-2031/openapi.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-2031/openapi.yaml) |
| `issue-2031/prefer` | 3.0.0 | Issue 2031 | [`issues/issue-2031/prefer/openapi.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-2031/prefer/openapi.yaml) |
| `issue-2113/common` | 3.0.4 | Common | [`issues/issue-2113/common/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-2113/common/spec.yaml) |
| `issue-2113` | 3.0.4 | API | [`issues/issue-2113/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-2113/spec.yaml) |
| `issue-2185` | 3.0.3 | test | [`issues/issue-2185/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-2185/spec.yaml) |
| `issue-2190` | 3.0.3 | test | [`issues/issue-2190/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-2190/spec.yaml) |
| `issue-2232` | 3.0.3 | test | [`issues/issue-2232/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-2232/spec.yaml) |
| `issue-2238` | 3.0.0 | Issue 2238 | [`issues/issue-2238/openapi.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-2238/openapi.yaml) |
| `issue-312` | 3.0.0 | Issue 312 test | [`issues/issue-312/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-312/spec.yaml) |
| `issue-52` | 3.0.2 | example | [`issues/issue-52/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-52/spec.yaml) |
| `issue-579` | 3.0.0 | Issue 579 test | [`issues/issue-579/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-579/spec.yaml) |
| `issue-832` | 3.0.2 | example | [`issues/issue-832/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-832/spec.yaml) |
| `issue-936` | 3.0.3 | Deep recursive cyclic refs example | [`issues/issue-936/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-936/spec.yaml) |
| `issue-grab_import_names` | 3.0.2 | ... | [`issues/issue-grab_import_names/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-grab_import_names/spec.yaml) |
| `issue-head-digit-of-httpheader` | 3.0.2 |  | [`issues/issue-head-digit-of-httpheader/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-head-digit-of-httpheader/spec.yaml) |
| `issue-head-digit-of-operation-id` | 3.0.2 |  | [`issues/issue-head-digit-of-operation-id/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-head-digit-of-operation-id/spec.yaml) |
| `issue-illegal_enum_names` | 3.0.2 | ... | [`issues/issue-illegal_enum_names/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-illegal_enum_names/spec.yaml) |
| `issue-removed-external-ref/spec-ext` | 3.0.2 |  | [`issues/issue-removed-external-ref/spec-ext.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue-removed-external-ref/spec-ext.yaml) |
| `issue1469` | 3.0.1 |  | [`issues/issue1469/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue1469/spec.yaml) |
| `issue1561` | 3.0.0 | When using `prefer-skip-optional-pointer-on-container-types`, container types do not have an 'optional pointer' | [`issues/issue1561/openapi.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue1561/openapi.yaml) |
| `issue1767` | 3.0.0 | An underscore in the name of a field is remapped to `Underscore` | [`issues/issue1767/openapi.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue1767/openapi.yaml) |
| `issue1825/spec` | 3.0.0 |  | [`issues/issue1825/spec/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue1825/spec/spec.yaml) |
| `issue193` | 3.0.0 | test schema | [`issues/issue193/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue193/spec.yaml) |
| `issue1957` | 3.0.0 | x-go-type and x-go-type-skip-optional-pointer should be possible to use together | [`issues/issue1957/openapi.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue1957/openapi.yaml) |
| `issue240` | 3.0.0 | Generate models | [`issues/issue240/api.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue240/api.yaml) |
| `issue518` | 3.0.1 |  | [`issues/issue518/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue518/spec.yaml) |
| `issue609` | 3.0.0 | Referencing an optional field, which has no information about the type it is will generate an `interface{}`, without the 'optional pointer' | [`issues/issue609/openapi.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/issues/issue609/openapi.yaml) |
| `name_conflict_resolution` | 3.0.1 | Comprehensive name collision resolution test | [`name_conflict_resolution/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/name_conflict_resolution/spec.yaml) |
| `outputoptions/name-normalizer` | 3.0.0 | Example code for the `name-normalizer` output option | [`outputoptions/name-normalizer/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/outputoptions/name-normalizer/spec.yaml) |
| `outputoptions/yaml-tags` | 3.0.1 | Cookie parameters | [`outputoptions/yaml-tags/spec.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/outputoptions/yaml-tags/spec.yaml) |
| `parameters` | 3.0.1 | Test Server | [`parameters/parameters.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/parameters/parameters.yaml) |
| `schemas` | 3.0.1 | Test Server | [`schemas/schemas.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/schemas/schemas.yaml) |
| `strict-server` | 3.0.0 | Strict server examples | [`strict-server/strict-schema.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/strict-server/strict-schema.yaml) |
| `test-schema` | 3.0.1 | Test Server | [`test-schema.yaml`](https://raw.githubusercontent.com/oapi-codegen/oapi-codegen/HEAD/internal/test/test-schema.yaml) |
