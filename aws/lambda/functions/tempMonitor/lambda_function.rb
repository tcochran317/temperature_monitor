require 'json'
require 'aws-sdk-dynamodb'

def lambda_handler(event:, context:)
    dynamodb = Aws::DynamoDB::Client.new

    temp_data = dynamodb.query({
        table_name: 'temp_humidity',
        key_condition_expression: 'device_id = :device_id',
        limit: 15,
        scan_index_forward: false,
        expression_attribute_values: {
            ':device_id' => ENV['DEVICE_ID']
        }
    })

    temp = ((temp_data.items.inject(0) { |sum,item| sum + item['temp_f'] })/15).round(1)
    if temp > ENV['ALERT_TEMP'].to_f
        temp_alert_users = dynamodb.query(
            table_name: 'users',
            index_name: 'tempAlert-index',
            select: 'ALL_PROJECTED_ATTRIBUTES',
            key_condition_expression: 'tempAlert = :temp_alert',
            expression_attribute_values: {
                ':temp_alert' => 'Y'
            }
        )
        temp_alert_users.items.each do |user|
            if user['active'] == 'Y'
                puts user['user_id']
                dynamodb.put_item({table_name: 'outbox', item: {
                    message_id: SecureRandom.uuid,
                    user_id: user['user_id'],
                    message_body: "High temperature alert: (#{sprintf('%.1f', temp)}F)",
                    created_at: Time.now.strftime('%Y-%m-%dT%H:%M:%S.%LZ'),
                    processed_at: nil
                }})
            end
        end
    end

    { statusCode: 200 }
end
