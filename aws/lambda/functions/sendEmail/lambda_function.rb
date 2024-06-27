require 'json'
require 'rubygems'
require 'aws-sdk-dynamodb'
require 'aws-sdk-sns'

def lambda_handler(event:, context:)

    dynamodb = Aws::DynamoDB::Client.new
    sns = Aws::SNS::Client.new

    messages=[]
    puts event
    event['Records'].each do |record|
        data = record['dynamodb']['NewImage']
        keys = record['dynamodb']['Keys']


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

        messages << data['message_body']['S']
    end

   # TODO: SNS ARN to environment variable
   sns.publish(topic_arn: 'arn:aws:sns:us-west-2:899670752587:freezer_monitor', message: messages.join('\n'))
end
