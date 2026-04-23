<!-- [scrai:start] -->
## storage

| File | Summary |
| --- | --- |
| buckets.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/routes/storage/buckets.rs. |
| mod.rs | S3-compatible storage route handlers.



Route table (path-style only, virtual-hosted-style deferred):



```text

GET  /                → list_buckets

PUT  /:bucket         → create_bucket

HEAD /:bucket         → head_bucket

DELETE /:bucket       → delete_bucket

GET  /:bucket         → list_objects_v2

PUT  /:bucket/*key    → put_object

GET  /:bucket/*key    → get_object

DELETE /:bucket/*key  → delete_object

HEAD /:bucket/*key    → head_object

```. |
| objects.rs | S3 object-level route handlers with inline metering. |
<!-- [scrai:end] -->
