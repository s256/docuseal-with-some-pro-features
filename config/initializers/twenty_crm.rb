# frozen_string_literal: true

Rails.application.config.after_initialize do
  status = Submissions::UploadToTwenty.health_check

  if !status[:configured]
    Rails.logger.info('[Twenty CRM] Integration not configured ' \
                      '(TWENTY_CRM_URL / TWENTY_CRM_API_KEY / TWENTY_CRM_FILE_FIELD_METADATA_ID not set)')
  elsif status[:reachable]
    Rails.logger.info("[Twenty CRM] Connected to #{status[:url]}")
  else
    Rails.logger.warn("[Twenty CRM] Configured but unreachable at #{status[:url]}: #{status[:error]}")
  end
rescue StandardError => e
  Rails.logger.warn("[Twenty CRM] Health check failed during startup: #{e.message}")
end
