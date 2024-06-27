require 'json'
require 'rubygems'
require 'twilio-ruby'
require 'aws-sdk-dynamodb'

def lambda_handler(event:, context:)

    dynamodb = Aws::DynamoDB::Client.new
    twilio = Twilio::REST::Client.new(ENV['TWILIO_ACCOUNT_SID'], ENV['TWILIO_AUTH_TOKEN'])

    event['Records'].each do |record|
        data = record['dynamodb']['NewImage']
        keys = record['dynamodb']['Keys']

        twilio.messages.create(
            body: data['message_body']['S'],
            from: ENV['TWILIO_PHONE_NUMBER'],
            to: data['user_id']['S']
        )

        dynamodb.update_item({table_name: 'outbox',
            key: {
                message_id: keys['message_id']['S'],
                created_at: keys['created_at']['S']
            },
            update_expression: 'SET processed_at = :processed_at',
            expression_attribute_values: {
                ':processed_at' => Time.now.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
            }
        })

    end

   { statusCode: 200 }
end
