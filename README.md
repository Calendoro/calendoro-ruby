# Calendoro for Ruby

**Status: not yet published to RubyGems.** The install command below works after the first release. Until then, use this folder directly.

Every method is generated from the Calendoro OpenAPI document. Standard library only, Ruby 3.1+. RBS signatures are in `sig/`.

```
gem install calendoro
```

```ruby
require "calendoro"

client = Calendoro::Client.new(api_key: "cdo_...") # or oauth_token: "cdoa_..."

me = client.account.get_api_identity
puts me.organization_id

client.webhooks.list_webhooks_iter.each { |hook| puts hook.url } # follows nextCursor

booking = client.bookings.create_booking(
  { eventTypeId: "...", startAt: "2026-11-02T15:00:00Z", timeZone: "Europe/Berlin", invitee: { name: "Ivy", email: "ivy@example.com" } },
  idempotency_key: "order-1234" # generated for you if omitted
)
```

Responses are `Calendoro::Models` objects with snake_case readers; `to_h` gives the wire form, including fields newer than this gem. Request bodies may be hashes with wire names or model objects.

**Retries**: `max_retries:` (default 2), exponential backoff with full jitter, honoring `Retry-After`. GET, PUT, DELETE and calls with an idempotency key retry on network errors, 408, 429 and 5xx. Other writes retry only on 429, since a failed one may have taken effect.

**Timeouts**: `timeout:` seconds, on the client (default 30) or any call.

**Errors**: `Calendoro::APIError` has `status`, `code`, `message`, `details`, `request_id`. Subclasses: `ValidationError`, `AuthenticationError`, `PermissionDeniedError`, `NotFoundError`, `ConflictError`, `RateLimitError`, `ServerError`. Network failures raise `ConnectionError` or `TimeoutError`.

**Webhooks**: pass the raw request body.

```ruby
event = Calendoro::Webhook.construct_event(request.raw_post, request.headers["Calendoro-Signature"], "whsec_...")
```

Methods documented as needing a user session refuse API keys and OAuth tokens; use `session_token:`.
