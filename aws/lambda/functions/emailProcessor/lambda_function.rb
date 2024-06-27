require 'json'
require 'aws-sdk-dynamodb'

def lambda_handler(event:, context:)
    params = {}
    puts event

    event['Records'].each do |record|
        mail = record['ses']['mail']
        details = mail['commonHeaders']

        dynamodb = Aws::DynamoDB::Client.new
        dynamodb.put_item(
        {
            table_name: 'inbox',
            item: {
                id: context.aws_request_id,
                user_id: details['returnPath'],
                message_id: mail['messageId'],
                message_body: details['subject'],
                received_at: Time.now.strftime('%Y-%m-%dT%H:%M:%S.%LZ'),
                processed_at: nil
            }
        })
    end

    { statusCode: 200, body: params.to_json }
end
