use anyhow::Result;
use reqwest::Client;
use serde::Deserialize;
use sha2::{Digest, Sha256};

#[derive(Clone)]
pub struct B2Client {
    key_id: String,
    app_key: String,
    pub bucket_name: String,
    http: Client,
}

#[derive(Deserialize)]
struct AuthResponse {
    #[serde(rename = "authorizationToken")]
    authorization_token: String,
    #[serde(rename = "apiUrl")]
    api_url: String,
    #[serde(rename = "downloadUrl")]
    download_url: String,
}

#[derive(Deserialize)]
struct UploadUrlResponse {
    #[serde(rename = "uploadUrl")]
    upload_url: String,
    #[serde(rename = "authorizationToken")]
    authorization_token: String,
}

impl B2Client {
    pub fn new(key_id: String, app_key: String, bucket_name: String) -> Self {
        Self {
            key_id,
            app_key,
            bucket_name,
            http: Client::new(),
        }
    }

    async fn authorize(&self) -> Result<AuthResponse> {
        let resp = self
            .http
            .get("https://api.backblazeb2.com/b2api/v3/b2_authorize_account")
            .basic_auth(&self.key_id, Some(&self.app_key))
            .send()
            .await?
            .error_for_status()?
            .json::<AuthResponse>()
            .await?;
        Ok(resp)
    }

    pub async fn upload(&self, key: &str, data: Vec<u8>, content_type: &str) -> Result<()> {
        let auth = self.authorize().await?;
        let bucket_id = self.get_bucket_id(&auth).await?;

        let upload_url_resp = self
            .http
            .post(format!("{}/b2api/v3/b2_get_upload_url", auth.api_url))
            .header("Authorization", &auth.authorization_token)
            .json(&serde_json::json!({ "bucketId": bucket_id }))
            .send()
            .await?
            .error_for_status()?
            .json::<UploadUrlResponse>()
            .await?;

        let hash = hex::encode(Sha256::digest(&data));
        let len = data.len();

        self.http
            .post(&upload_url_resp.upload_url)
            .header("Authorization", &upload_url_resp.authorization_token)
            .header("X-Bz-File-Name", urlencoding::encode(key).as_ref())
            .header("Content-Type", content_type)
            .header("Content-Length", len)
            .header("X-Bz-Content-Sha256", &hash)
            .body(data)
            .send()
            .await?
            .error_for_status()?;

        Ok(())
    }

    pub async fn download(&self, key: &str) -> Result<Vec<u8>> {
        let auth = self.authorize().await?;
        let url = format!(
            "{}/file/{}/{}",
            auth.download_url,
            urlencoding::encode(&self.bucket_name),
            urlencoding::encode(key),
        );
        let data = self
            .http
            .get(&url)
            .header("Authorization", &auth.authorization_token)
            .send()
            .await?
            .error_for_status()?
            .bytes()
            .await?
            .to_vec();
        Ok(data)
    }

    pub async fn delete(&self, key: &str) -> Result<()> {
        let auth = self.authorize().await?;
        let list: serde_json::Value = self
            .http
            .post(format!("{}/b2api/v3/b2_list_file_names", auth.api_url))
            .header("Authorization", &auth.authorization_token)
            .json(&serde_json::json!({
                "bucketName": self.bucket_name,
                "prefix": key,
                "maxFileCount": 1,
            }))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;

        if let Some(file) = list["files"].as_array().and_then(|a| a.first()) {
            let file_id = file["fileId"].as_str().unwrap_or_default();
            self.http
                .post(format!("{}/b2api/v3/b2_delete_file_version", auth.api_url))
                .header("Authorization", &auth.authorization_token)
                .json(&serde_json::json!({ "fileName": key, "fileId": file_id }))
                .send()
                .await?
                .error_for_status()?;
        }

        Ok(())
    }

    async fn get_bucket_id(&self, auth: &AuthResponse) -> Result<String> {
        let resp: serde_json::Value = self
            .http
            .post(format!("{}/b2api/v3/b2_list_buckets", auth.api_url))
            .header("Authorization", &auth.authorization_token)
            .json(&serde_json::json!({ "bucketName": self.bucket_name }))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;

        let id = resp["buckets"][0]["bucketId"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("bucket not found"))?
            .to_string();

        Ok(id)
    }
}

pub fn sha256_hex(data: &[u8]) -> String {
    hex::encode(Sha256::digest(data))
}

pub fn brotli_compress(data: &[u8]) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    let params = brotli::enc::BrotliEncoderParams::default();
    brotli::BrotliCompress(&mut std::io::Cursor::new(data), &mut out, &params)?;
    Ok(out)
}

pub fn brotli_decompress(data: &[u8]) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    brotli::BrotliDecompress(&mut std::io::Cursor::new(data), &mut out)?;
    Ok(out)
}
