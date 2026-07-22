use api::secrets::{aws::SsmNodeSecretManager, NodeSecretManager};
use aws_sdk_ssm::error::SdkError;
use aws_sdk_ssm::operation::get_parameter::GetParameterError;
use uuid::Uuid;

#[tokio::test]
#[ignore = "live AWS SSM validation; requires production-safe AWS credentials"]
async fn ssm_live_node_secret_rotation_delete_removes_current_and_previous_parameters() {
    let config = aws_config::load_defaults(aws_config::BehaviorVersion::latest()).await;
    let client = aws_sdk_ssm::Client::new(&config);
    let manager = SsmNodeSecretManager::new(client.clone());
    let node_id = format!("s2-synthetic-{}", Uuid::new_v4());
    let region = std::env::var("AWS_REGION")
        .or_else(|_| std::env::var("AWS_DEFAULT_REGION"))
        .unwrap_or_else(|_| "us-east-1".to_string());

    let exercise_result = exercise_node_secret_rotation(&manager, &node_id, &region).await;
    let cleanup_result = manager.delete_node_api_key(&node_id, &region).await;

    assert!(
        exercise_result.is_ok(),
        "synthetic SSM node secret exercise failed for {node_id}: {:?}",
        exercise_result.err()
    );
    assert!(
        cleanup_result.is_ok(),
        "synthetic SSM node secret cleanup failed for {node_id}: {:?}",
        cleanup_result.err()
    );

    assert_parameter_absent(&client, &format!("/fjcloud/{node_id}/api-key")).await;
    assert_parameter_absent(&client, &format!("/fjcloud/{node_id}/api-key-previous")).await;
}

async fn exercise_node_secret_rotation(
    manager: &SsmNodeSecretManager,
    node_id: &str,
    region: &str,
) -> Result<(), api::secrets::NodeSecretError> {
    let created_key = manager.create_node_api_key(node_id, region).await?;
    let fetched_key = manager.get_node_api_key(node_id, region).await?;
    assert!(
        fetched_key == created_key,
        "created synthetic node key must round-trip through SSM for {node_id}"
    );

    let (old_key, new_key) = manager.rotate_node_api_key(node_id, region).await?;
    assert!(
        old_key == created_key,
        "rotation must return the originally created synthetic key as old_key for {node_id}"
    );
    assert!(
        new_key != old_key,
        "rotation must issue a distinct synthetic node key for {node_id}"
    );

    manager.delete_node_api_key(node_id, region).await
}

async fn assert_parameter_absent(client: &aws_sdk_ssm::Client, parameter_name: &str) {
    let result = client
        .get_parameter()
        .name(parameter_name)
        .with_decryption(true)
        .send()
        .await;

    assert!(
        matches!(
            result,
            Err(SdkError::ServiceError(ref service_error))
                if matches!(service_error.err(), GetParameterError::ParameterNotFound(_))
        ),
        "expected synthetic SSM parameter to be absent after cleanup: {parameter_name}"
    );
}
