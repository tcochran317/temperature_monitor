require 'json'
require 'rubygems'
require 'aws-sdk-dynamodb'
require 'aws-sdk-ses'

def lambda_handler(event:, context:)

    dynamodb = Aws::DynamoDB::Client.new
    ses = Aws::SES::Client.new

    messages=Hash.new{ |h, k| h[k] = [] }

    puts event
    event['Records'].each do |record|
        data = record['dynamodb']['NewImage']
        keys = record['dynamodb']['Keys']


        dynamodb.update_item({table_name: 'message_sent',
            key: {
                message_id: keys['message_id']['S'],
                created_at: keys['created_at']['S']
            },
            update_expression: 'SET processed_at = :processed_at',
            expression_attribute_values: {
                ':processed_at' => Time.now.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
            }
        })

        messages[data['user_id']['S']] << data['message_body']['S']
    end

    messages.each do |to_addr, message_body|
        ses.send_email({
            destination: {
                to_addresses: [to_addr]
            },
            message: {
                body: {
                    text: {
                        data: message_body.join('\n')
                    }
                },
                subject: {
                    data: 'Monitor alert'
                }
            },
            source: ENV['MONITOR_EMAIL_ADDRESS']
        })
    end
end
