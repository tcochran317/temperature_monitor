require 'json'
require 'cgi'
require 'aws-sdk-dynamodb'

def lambda_handler(event:, context:)
    params = {}
    event['body'].split('&').map do |param|
        tokens = param.split('=')
        params[tokens[0]] = CGI.unescape(tokens[1])
    end

    dynamodb = Aws::DynamoDB::Client.new
    dynamodb.put_item({table_name: 'inbox', item: {
        id: context.aws_request_id,
        user_id: params['From'],
        message_id: params['MessageSid'],
        message_body: params['Body'],
        received_at: Time.now.strftime('%Y-%m-%dT%H:%M:%S.%LZ'),
        processed_at: nil
    }})

    { statusCode: 200, body: params.to_json }
end
