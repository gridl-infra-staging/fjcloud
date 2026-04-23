//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/storage/s3_xml.rs.

use quick_xml::events::{BytesDecl, BytesEnd, BytesStart, BytesText, Event};
use quick_xml::Writer;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// A bucket entry for `ListAllMyBucketsResult`.
#[derive(Debug, Clone)]
pub struct BucketEntry {
    pub name: String,
    pub creation_date: String,
}

/// Parameters for `ListBucketResult` (ListObjectsV2).
#[derive(Debug, Clone)]
pub struct ListObjectsV2Params {
    pub bucket: String,
    pub prefix: String,
    pub max_keys: u32,
    pub key_count: u32,
    pub is_truncated: bool,
    pub continuation_token: Option<String>,
    pub next_continuation_token: Option<String>,
}

/// An object entry for `ListBucketResult`.
#[derive(Debug, Clone)]
pub struct ObjectEntry {
    pub key: String,
    pub last_modified: String,
    pub etag: String,
    pub size: u64,
    pub storage_class: String,
}

// ---------------------------------------------------------------------------
// Builders
// ---------------------------------------------------------------------------

/// Build an S3 `<Error>` XML response.
pub fn error_response(code: &str, message: &str, resource: &str, request_id: &str) -> String {
    let mut writer = xml_writer();
    write_xml_decl(&mut writer);

    writer
        .create_element("Error")
        .write_inner_content(|w| {
            write_text_element(w, "Code", code)?;
            write_text_element(w, "Message", message)?;
            write_text_element(w, "Resource", resource)?;
            write_text_element(w, "RequestId", request_id)?;
            Ok(())
        })
        .expect("XML write error");

    String::from_utf8(writer.into_inner().into_inner()).expect("UTF-8 XML")
}

/// Build an S3 `<ListAllMyBucketsResult>` XML response.
pub fn list_buckets_result(owner_id: &str, display_name: &str, buckets: &[BucketEntry]) -> String {
    let mut writer = xml_writer();
    write_xml_decl(&mut writer);

    let mut root = BytesStart::new("ListAllMyBucketsResult");
    root.push_attribute(("xmlns", "http://s3.amazonaws.com/doc/2006-03-01/"));

    writer.write_event(Event::Start(root)).expect("XML write");

    // <Owner>
    writer
        .create_element("Owner")
        .write_inner_content(|w| {
            write_text_element(w, "ID", owner_id)?;
            write_text_element(w, "DisplayName", display_name)?;
            Ok(())
        })
        .expect("XML write");

    // <Buckets>
    if buckets.is_empty() {
        writer
            .write_event(Event::Empty(BytesStart::new("Buckets")))
            .expect("XML write");
    } else {
        writer
            .write_event(Event::Start(BytesStart::new("Buckets")))
            .expect("XML write");

        for bucket in buckets {
            writer
                .create_element("Bucket")
                .write_inner_content(|w| {
                    write_text_element(w, "Name", &bucket.name)?;
                    write_text_element(w, "CreationDate", &bucket.creation_date)?;
                    Ok(())
                })
                .expect("XML write");
        }

        writer
            .write_event(Event::End(BytesEnd::new("Buckets")))
            .expect("XML write");
    }

    writer
        .write_event(Event::End(BytesEnd::new("ListAllMyBucketsResult")))
        .expect("XML write");

    String::from_utf8(writer.into_inner().into_inner()).expect("UTF-8 XML")
}

/// Build an S3 `<ListBucketResult>` XML response (ListObjectsV2).
pub fn list_objects_v2_result(params: &ListObjectsV2Params, objects: &[ObjectEntry]) -> String {
    let mut writer = xml_writer();
    write_xml_decl(&mut writer);

    let mut root = BytesStart::new("ListBucketResult");
    root.push_attribute(("xmlns", "http://s3.amazonaws.com/doc/2006-03-01/"));

    writer.write_event(Event::Start(root)).expect("XML write");

    write_text_element(&mut writer, "Name", &params.bucket).expect("XML write");
    write_text_element(&mut writer, "Prefix", &params.prefix).expect("XML write");
    write_text_element(&mut writer, "MaxKeys", &params.max_keys.to_string()).expect("XML write");
    write_text_element(&mut writer, "KeyCount", &params.key_count.to_string()).expect("XML write");
    write_text_element(
        &mut writer,
        "IsTruncated",
        if params.is_truncated { "true" } else { "false" },
    )
    .expect("XML write");

    if let Some(ref token) = params.continuation_token {
        write_text_element(&mut writer, "ContinuationToken", token).expect("XML write");
    }
    if let Some(ref token) = params.next_continuation_token {
        write_text_element(&mut writer, "NextContinuationToken", token).expect("XML write");
    }

    for obj in objects {
        writer
            .create_element("Contents")
            .write_inner_content(|w| {
                write_text_element(w, "Key", &obj.key)?;
                write_text_element(w, "LastModified", &obj.last_modified)?;
                write_text_element(w, "ETag", &obj.etag)?;
                write_text_element(w, "Size", &obj.size.to_string())?;
                write_text_element(w, "StorageClass", &obj.storage_class)?;
                Ok(())
            })
            .expect("XML write");
    }

    writer
        .write_event(Event::End(BytesEnd::new("ListBucketResult")))
        .expect("XML write");

    String::from_utf8(writer.into_inner().into_inner()).expect("UTF-8 XML")
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn xml_writer() -> Writer<std::io::Cursor<Vec<u8>>> {
    Writer::new(std::io::Cursor::new(Vec::new()))
}

fn write_xml_decl(writer: &mut Writer<std::io::Cursor<Vec<u8>>>) {
    writer
        .write_event(Event::Decl(BytesDecl::new("1.0", Some("UTF-8"), None)))
        .expect("XML decl write");
}

/// Writes a complete XML element with text content:
/// `<tag>text</tag>`. Emits `Start`, `Text`, and `End` events via
/// the `quick_xml` writer.
fn write_text_element(
    writer: &mut Writer<std::io::Cursor<Vec<u8>>>,
    tag: &str,
    text: &str,
) -> Result<(), std::io::Error> {
    writer
        .write_event(Event::Start(BytesStart::new(tag)))
        .map_err(std::io::Error::other)?;
    writer
        .write_event(Event::Text(BytesText::new(text)))
        .map_err(std::io::Error::other)?;
    writer
        .write_event(Event::End(BytesEnd::new(tag)))
        .map_err(std::io::Error::other)?;
    Ok(())
}
