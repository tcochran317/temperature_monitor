require 'json'
require 'aws-sdk-dynamodb'

def lambda_handler(event:, context:)
    dynamodb = Aws::DynamoDB::Client.new

    temp_data = dynamodb.query({
        table_name: 'temp_data', 
        key_condition_expression: 'device_id = :device_id',
        limit: 1,
        scan_index_forward: false,
        expression_attribute_values: {
            ':device_id' => ENV['DEVICE_ID']
        }
    })
 
    published_at = Time.parse(temp_data.items.first['published_at'])
    if published_at < (Time.now - 3600)
        puts "Last temp data received at #{published_at.strftime('%Y-%m-%d %H:%M:%S')}"
        alert_users = dynamodb.query(
            table_name: 'users',
            index_name: 'heartbeatAlert-index',
            select: 'ALL_PROJECTED_ATTRIBUTES',
            key_condition_expression: 'heartbeatAlert = :heartbeat_alert',
            expression_attribute_values: {
                ':heartbeat_alert' => 'Y'
            }
        )
        alert_users.items.each do |user|
            if user['active'] == 'Y'
                puts user['user_id']
                dynamodb.put_item({table_name: 'message_sent', item: {
                    message_id: SecureRandom.uuid,
                    user_id: user['user_id'],
                    message_body: "No temp data received since #{published_at.strftime('%Y-%m-%d, %H:%M:%S')}",
                    created_at: Time.now.strftime('%Y-%m-%dT%H:%M:%S.%LZ'),
                    processed_at: nil
                }})
            end
        end
    end
    
    { statusCode: 200 }
end
