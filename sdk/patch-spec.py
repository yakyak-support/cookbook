#!/usr/bin/env python3
"""Patch the live YakYak OpenAPI spec so it passes openapi-generator codegen.

The published spec at https://api.yakyak.ai/api/docs-json has a couple of quirks
that break code generation:

  1. Dangling $refs — e.g. `CampaignResponseDto` references
     `#/components/schemas/CampaignMovieDto`, but that schema is not defined under
     `components.schemas`. The generator then emits imports to a model it never
     created, so the TypeScript build fails.

  2. OpenAPI 3.1 `examples` (plural) used inside 3.0 *schema* objects (e.g.
     `SendFreeTrialDto.email.examples`). `examples` is only valid on MediaType /
     Parameter objects in 3.0, not on schemas, so validation rejects it.

  3. Missing `requestBody` on @Body() routes — most `workflow/*` POSTs read a JSON
     body but declare no schema, so generated methods cannot send a payload. We
     inject request bodies (typed DTOs for the routes the cookbook uses, permissive
     objects elsewhere) so e.g. `client.workflow.createCampaign({...})` works.

This script applies targeted, generic fixes and writes the patched spec out. It is
intentionally conservative: it only strips `examples` *within components.schemas*
(where it is never valid in 3.0) and only stubs refs that are genuinely missing.

Usage:
    python sdk/patch-spec.py <input.json> <output.json>
"""
import json
import sys


def fix_datetime_field_clash(node):
    """Strip format:'date-time' from any property literally named 'datetime'.

    pydantic 2.11+ raises PydanticUserError('unevaluable-type-annotation') when
    a field is named 'datetime' and typed as datetime.datetime — the name shadows
    the type import in the class scope. openapi-generator emits that clash when a
    property named 'datetime' carries format:'date-time'. Stripping the format
    makes the generator emit StrictStr instead, which is wire-compatible (the value
    is still an ISO-8601 string) and doesn't clash.
    """
    fixed = 0
    if isinstance(node, dict):
        props = node.get("properties", {})
        if "datetime" in props and isinstance(props["datetime"], dict):
            if props["datetime"].get("format") == "date-time":
                del props["datetime"]["format"]
                fixed += 1
        for v in node.values():
            fixed += fix_datetime_field_clash(v)
    elif isinstance(node, list):
        for item in node:
            fixed += fix_datetime_field_clash(item)
    return fixed


def strip_schema_enums(node):
    """Recursively remove `enum` constraints anywhere under a schema subtree.

    Several enums in the live spec are incomplete and drift from reality (e.g.
    `ExecutionLogEntryDto.type` lists only script/image/movie but the API also
    returns subtitlesMovie, burn, movieConcat, …). The strict Python generator
    raises a ValidationError when it deserializes a value outside the enum, so we
    drop enums and treat these fields as plain strings. typescript-fetch ignores
    enums at runtime, so this only matters for Python — but we strip for both so
    the clients behave identically.
    """
    removed = 0
    if isinstance(node, dict):
        if "enum" in node:
            del node["enum"]
            removed += 1
        for value in node.values():
            removed += strip_schema_enums(value)
    elif isinstance(node, list):
        for item in node:
            removed += strip_schema_enums(item)
    return removed


def strip_schema_examples(node):
    """Recursively remove `examples` keys anywhere under a schema subtree.

    Safe because this is only ever called on components.schemas, where `examples`
    is not a valid keyword in OpenAPI 3.0 (only `example` is).
    """
    removed = 0
    if isinstance(node, dict):
        if "examples" in node:
            del node["examples"]
            removed += 1
        for value in node.values():
            removed += strip_schema_examples(value)
    elif isinstance(node, list):
        for item in node:
            removed += strip_schema_examples(item)
    return removed


def add_missing_response_content(paths):
    """Give success responses a body schema so the client returns the payload.

    typescript-fetch (and the Python generator) emit a `void`/`None` return for
    any 2xx response that has no `content`, silently discarding the JSON body.
    The live spec omits response schemas on almost every endpoint, so methods
    like `getStyles()` resolve to `undefined` even though the API returns data.

    Inject a permissive `application/json` object schema for every 2xx response
    (other than 204 No Content) that lacks one. The generated method then parses
    and returns the body, typed loosely as an object. Error responses (4xx/5xx)
    are left untouched — they don't affect the success return type.
    """
    added = 0
    for ops in paths.values():
        if not isinstance(ops, dict):
            continue
        for op in ops.values():
            if not isinstance(op, dict):
                continue
            for code, resp in (op.get("responses") or {}).items():
                if not isinstance(resp, dict):
                    continue
                if not code.startswith("2") or code == "204":
                    continue
                if "content" in resp:
                    continue
                resp["content"] = {
                    "application/json": {
                        "schema": {
                            "type": "object",
                            "additionalProperties": True,
                            "description": (
                                "Auto-added by sdk/patch-spec.py: the source spec "
                                "declared no response body schema, so the client "
                                "would otherwise return void and drop the payload."
                            ),
                        }
                    }
                }
                added += 1
    return added


# Request bodies the live spec omits. NestJS controllers that read the body via
# `@Body()` without a typed DTO (or via `@Body('field')`) produce operations with
# no `requestBody`, so the generators emit methods that cannot send a payload
# (typescript-fetch: only `initOverrides`; python: no body param at all). We inject
# a named DTO per endpoint so the generated method takes a typed body, e.g.
# `client.workflow.createCampaign({ createCampaignDto: { ... } })`.
#
# Keyed by (METHOD, path). `props` are best-effort and permissive
# (additionalProperties stays on, so unknown/extra fields still pass). Shapes were
# verified against the live API + a web-app capture; see course/ for usage.
S = "string"
KNOWN_REQUEST_BODIES = {
    ("post", "/workflow/create-campaign"): ("CreateCampaignDto",
        {"userId": S, "prompt": S, "name": S, "description": S, "styleId": S,
         "aspectRatio": S, "animationType": S, "imageQuality": S,
         "mode": S, "skipSoundtrack": "boolean", "eventId": S}, ["userId"]),
    ("post", "/workflow/start-campaign"): ("StartCampaignDto",
        {"userId": S, "campaignId": S}, ["campaignId"]),
    ("post", "/workflow/gen-movie-cast"): ("GenMovieCastDto",
        {"movieId": S, "roleCounts": "object"}, ["movieId"]),
    # gen-movie-screenplay already has a typed GenMovieScreenplayRequestDto in the spec.
    ("post", "/workflow/gen-custom-cast-image"): ("GenCustomCastImageDto",
        {"movieId": S, "characterName": S, "description": S}, ["movieId", "characterName"]),
    ("post", "/workflow/delete-scene"): ("DeleteSceneDto",
        {"sceneId": S}, ["sceneId"]),
    ("post", "/workflow/insert-media-scene"): ("InsertMediaSceneDto",
        {"movieId": S, "sceneNumber": "number", "mediaUrl": S, "title": S, "mediaId": S},
        ["movieId", "mediaUrl"]),
    ("post", "/workflow/save-movie-custom-cast"): ("SaveMovieCustomCastDto",
        {"movieId": S, "characters": "array"}, ["movieId", "characters"]),
    ("post", "/workflow/set-cast"): ("SetCastDto",
        {"movieId": S, "cast": "array"}, ["movieId", "cast"]),
    ("post", "/workflow/fork-campaign"): ("ForkCampaignDto",
        {"userId": S, "sourceCampaignId": S, "sourceMovieId": S}, ["userId"]),
    ("post", "/workflow/update-campaign-settings"): ("UpdateCampaignSettingsDto",
        {"campaignId": S, "aspectRatio": S, "animationType": S,
         "imageQuality": S, "additionalDescription": S}, ["campaignId"]),
    ("post", "/workflow/switch-campaign-mode"): ("SwitchCampaignModeDto",
        {"campaignId": S, "mode": S}, ["campaignId", "mode"]),
    ("post", "/workflow/create-scene"): ("CreateSceneDto",
        {"userId": S, "movieId": S, "sceneNumber": "number", "title": S,
         "story": S, "dialogue": S, "leadCast": S, "backgroundColor": S,
         "generate": "boolean"}, ["movieId"]),
    ("post", "/workflow/update-scene-dialogue"): ("UpdateSceneDialogueDto",
        {"userId": S, "sceneId": S, "dialogue": S}, ["sceneId"]),
    ("post", "/workflow/rerun-scene"): ("RerunSceneDto",
        {"sceneId": S, "from": S}, ["sceneId"]),
    ("post", "/workflow/export-render"): ("ExportRenderDto",
        {"movieId": S, "force": "boolean"}, ["movieId"]),
    ("post", "/workflow/set-soundtrack-audio"): ("SetSoundtrackAudioDto",
        {"movieId": S, "audioPath": S}, ["movieId", "audioPath"]),
    ("post", "/workflow/select-soundtrack-history"): ("SelectSoundtrackHistoryDto",
        {"movieId": S, "audioPath": S}, ["movieId"]),
}

# multipart/form-data file-upload routes. These are NOT given a JSON request body (that
# would mislabel them); the hand-written SDK `uploads.*` facade wraps them instead.
UPLOAD_PATHS = {
    "/workflow/upload-cast-character-image",
    "/workflow/upload-scene-image",
    "/workflow/upload-user-media",
    "/workflow/upload-soundtrack-audio",
    "/workflow/upload-scene-movie",
}


def add_missing_request_bodies(spec):
    """Inject request-body schemas for mutating operations that lack one.

    Named DTOs (KNOWN_REQUEST_BODIES) get typed properties so the generated method
    has an ergonomic, documented body param. Every other body-less POST/PUT/PATCH
    gets a permissive inline object body so it can at least send arbitrary JSON
    instead of silently dropping the payload.
    """
    schemas = spec.setdefault("components", {}).setdefault("schemas", {})
    named = generic = 0
    for path, ops in spec.get("paths", {}).items():
        if not isinstance(ops, dict):
            continue
        for method, op in ops.items():
            if method.lower() not in ("post", "put", "patch"):
                continue
            if not isinstance(op, dict) or "requestBody" in op:
                continue
            # Upload routes are multipart/form-data — injecting a generic JSON body would
            # mislabel them and produce generated methods that silently drop the file. Leave
            # them body-less; the hand-written SDK `uploads.*` facade handles them instead.
            if path in UPLOAD_PATHS:
                continue
            known = KNOWN_REQUEST_BODIES.get((method.lower(), path))
            if known:
                name, props, required = known

                def prop_schema(t):
                    if t == "array":
                        return {"type": "array", "items": {"type": "object", "additionalProperties": True}}
                    if t == "object":
                        return {"type": "object", "additionalProperties": True}
                    return {"type": t}

                # Don't clobber a schema the source spec already defines (e.g. SetCastDto).
                if name not in schemas:
                    schema = {
                        "type": "object",
                        "additionalProperties": True,
                        "properties": {k: prop_schema(t) for k, t in props.items()},
                        "description": "Auto-added by sdk/patch-spec.py (the source spec declared no requestBody for this route).",
                    }
                    if required:
                        schema["required"] = required
                    schemas[name] = schema
                op["requestBody"] = {
                    "required": bool(required),
                    "content": {"application/json": {"schema": {"$ref": f"#/components/schemas/{name}"}}},
                }
                named += 1
            else:
                op["requestBody"] = {
                    "required": False,
                    "content": {"application/json": {"schema": {
                        "type": "object",
                        "additionalProperties": True,
                        "description": "Auto-added by sdk/patch-spec.py: source spec declared no requestBody for this route.",
                    }}},
                }
                generic += 1
    return named, generic


def add_post_created_responses(spec):
    """Map a 201 response on POST operations that only declare 200.

    NestJS returns 201 Created from POST handlers by default, but the spec
    documents many of them as 200. The strict Python generator only deserializes
    the declared status code, so a real 201 yields `None` (typescript-fetch is
    lenient and returns any 2xx body). Clone the 200 response onto 201 (or add a
    permissive one) so the generated client returns the payload either way.
    """
    added = 0
    permissive = {"application/json": {"schema": {
        "type": "object", "additionalProperties": True,
        "description": "Auto-added by sdk/patch-spec.py: POST returns 201 Created.",
    }}}
    for ops in spec.get("paths", {}).values():
        if not isinstance(ops, dict):
            continue
        op = ops.get("post")
        if not isinstance(op, dict):
            continue
        responses = op.setdefault("responses", {})
        if "201" in responses:
            continue
        ok = responses.get("200")
        responses["201"] = {
            "description": (ok or {}).get("description", "Created"),
            "content": (ok or {}).get("content", permissive),
        }
        added += 1
    return added


def add_pat_routes(spec):
    """Add the Personal Access Token routes the live spec omits.

    The web app creates non-expiring PATs via `POST /access-tokens` (body =
    CreateAccessTokenDto, response = { token, metadata }), but the route isn't in
    the published spec, so the generated SDK can't expose it. Add it under the
    Users tag so it surfaces as `client.users.createAccessToken({...})`.
    """
    paths = spec.setdefault("paths", {})
    if "/access-tokens" in paths:
        return 0
    obj = {"type": "object", "additionalProperties": True}
    paths["/access-tokens"] = {
        "post": {
            "tags": ["users"],
            "operationId": "UsersController_createAccessToken",
            "summary": "Create a personal access token (non-expiring) — added by sdk/patch-spec.py",
            "requestBody": {"required": True, "content": {"application/json": {
                "schema": {"$ref": "#/components/schemas/CreateAccessTokenDto"}}}},
            "responses": {"201": {"description": "Created", "content": {"application/json": {"schema": obj}}}},
        },
    }
    return 1


def collect_schema_refs(node, refs):
    """Collect every `#/components/schemas/<name>` reference in the document."""
    prefix = "#/components/schemas/"
    if isinstance(node, dict):
        ref = node.get("$ref")
        if isinstance(ref, str) and ref.startswith(prefix):
            refs.add(ref[len(prefix):])
        for value in node.values():
            collect_schema_refs(value, refs)
    elif isinstance(node, list):
        for item in node:
            collect_schema_refs(item, refs)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)

    src, dst = sys.argv[1], sys.argv[2]
    with open(src) as f:
        spec = json.load(f)

    # 0. Fill publisher metadata the live spec omits. The Python generator reads
    #    author/license straight from `info`, and both generators read `servers`
    #    for the client base URL. typescript-fetch ignores `info.contact`/
    #    `info.license`, so these are no-ops for the npm build (which sets the
    #    same fields via `npm pkg set` in the workflow).
    info = spec.setdefault("info", {})
    info.setdefault("contact", {
        "name": "YakYak Support",
        "email": "support@yakyak.ai",
        "url": "https://github.com/yakyak-support/cookbook",
    })
    info.setdefault("license", {
        "name": "Apache-2.0",
        "url": "https://www.apache.org/licenses/LICENSE-2.0",
    })
    # Safety net: if the deployed API hasn't yet published a `servers` entry, the
    # generators would otherwise fall back to http://localhost.
    if not spec.get("servers"):
        spec["servers"] = [{"url": "https://api.yakyak.ai"}]

    schemas = spec.setdefault("components", {}).setdefault("schemas", {})

    # 0a. Fix datetime field name clash (pydantic 2.11+ rejects a field named
    #     'datetime' typed as datetime.datetime; strip format:'date-time' so the
    #     generator emits StrictStr instead). Applied to the whole spec so it
    #     catches both named schemas and inline requestBody schemas.
    datetime_clashes = fix_datetime_field_clash(spec)

    # 1. Strip schema-level `examples` (3.1 leakage) from every defined schema.
    removed = strip_schema_examples(schemas)

    # 1a. Strip `enum` constraints (several are incomplete and break the strict
    #     Python client when the API returns a newer value).
    enums = strip_schema_enums(schemas)

    # 1b. Give success responses a body schema so generated methods return the
    #     payload instead of `void` (the live spec omits response schemas).
    bodies = add_missing_response_content(spec.get("paths", {}))

    # 1c. Give mutating operations a request body so generated methods can send a
    #     payload (the live spec omits requestBody on @Body() routes).
    named_reqs, generic_reqs = add_missing_request_bodies(spec)

    # 1d. Map a 201 response on POSTs that only declare 200 (NestJS returns 201),
    #     so the strict Python generator deserializes the real status code.
    created = add_post_created_responses(spec)

    # 1e. Add the Personal Access Token route the live spec omits.
    pat = add_pat_routes(spec)

    # 2. Stub any referenced-but-undefined schema so $refs resolve and the
    #    generator produces a (permissive) model instead of a dangling import.
    referenced = set()
    collect_schema_refs(spec, referenced)
    missing = sorted(referenced - set(schemas))
    for name in missing:
        schemas[name] = {
            "type": "object",
            "additionalProperties": True,
            "description": (
                "Auto-stubbed by sdk/patch-spec.py: referenced by the spec but "
                "not defined under components.schemas in the source document."
            ),
        }

    with open(dst, "w") as f:
        json.dump(spec, f, indent=2)

    print(f"patched spec written to {dst}")
    print(f"  stripped format:date-time from {datetime_clashes} 'datetime'-named field(s)")
    print(f"  removed {removed} schema-level 'examples' key(s)")
    print(f"  removed {enums} schema-level 'enum' constraint(s)")
    print(f"  added body schema to {bodies} success response(s)")
    print(f"  added request body to {named_reqs} named + {generic_reqs} generic operation(s)")
    print(f"  mapped 201 on {created} POST operation(s)")
    print(f"  added {pat} PAT route(s)")
    print(f"  stubbed {len(missing)} missing schema(s): {missing or 'none'}")


if __name__ == "__main__":
    main()
