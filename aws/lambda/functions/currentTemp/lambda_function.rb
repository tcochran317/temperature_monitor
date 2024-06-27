require 'json'
require 'aws-sdk-dynamodb'

def lambda_handler(event:, context:)
    dynamodb = Aws::DynamoDB::Client.new

    response = dynamodb.query({
        table_name: 'temp_humidity',
        key_condition_expression: 'device_id = :device_id',
        limit: 1,
        scan_index_forward: false,
        expression_attribute_values: {
            ':device_id' => ENV['DEVICE_ID']
        }
    }).items.first

    record = event['Records']&.first
    message = "Current temperature is #{sprintf('%.1f', response['temp_f'])}F (#{sprintf('%.1f', response['temp_c'])}C)"
    user_id = record['dynamodb']['NewImage']['user_id']['S']

    dynamodb.put_item({table_name: 'outbox', item: {
        message_id: SecureRandom.uuid,
        user_id: user_id,
        message_body: message,
        created_at: Time.now.strftime('%Y-%m-%dT%H:%M:%S.%LZ'),
        processed_at: nil
    }})

    { statusCode: 200 }
end
