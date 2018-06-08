RSpec.describe FaradayMiddleware::AwsSigV4 do
  def faraday(options = {})
    options = {
      url: 'https://apigateway.us-east-1.amazonaws.com'
    }.merge(options)

    Faraday.new(options) do |faraday|
      aws_sigv4_options = {
        service: 'apigateway',
        region: 'us-east-1',
        credentials_provider: Aws::InstanceProfileCredentials.new,
      }

      faraday.request :aws_sigv4, aws_sigv4_options
      faraday.response :json, :content_type => /\bjson\b/

      faraday.adapter(:test, Faraday::Adapter::Test::Stubs.new) do |stub|
        yield(stub)
      end
    end
  end

  let(:response) do
    {'accountUpdate'=>
      {'name'=>nil,
       'template'=>false,
       'templateSkipList'=>nil,
       'title'=>nil,
       'updateAccountInput'=>nil},
     'cloudwatchRoleArn'=>nil,
     'self'=>
      {'__type'=>
        'GetAccountRequest:http://internal.amazon.com/coral/com.amazonaws.backplane.controlplane/',
       'name'=>nil,
       'template'=>false,
       'templateSkipList'=>nil,
       'title'=>nil},
     'throttleSettings'=>{'burstLimit'=>1000, 'rateLimit'=>500.0}}
  end

  let(:expected_headers) do
    {'host'=>'apigateway.us-east-1.amazonaws.com',
     'x-amz-content-sha256'=>
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'}
  end

  let(:authz_tmpl) do
    'AWS4-HMAC-SHA256 Credential=%{access_key_id}/20150101/us-east-1/apigateway/aws4_request, ' +
    "SignedHeaders=host;user-agent;x-amz-content-sha256;x-amz-date;x-amz-security-token, " +
    "Signature=%{signature}"
  end

  before do
    stub_const('Net::HTTP::HAVE_ZLIB', true)

    allow_any_instance_of(Aws::InstanceProfileCredentials).to receive(:get_credentials) {
      JSON.dump({
        'AccessKeyId' => "akid#{Time.now.to_i}",
        'SecretAccessKey' => "secret#{Time.now.to_i}",
        'Token' => "token#{Time.now.to_i}",
        'Expiration' => Time.now + 3600,
      })
    }
  end

  specify do
    account_headers = nil

    client = faraday do |stub|
      stub.get('/account') do |env|
        account_headers = env[:request_headers]
        [200, {'Content-Type' => 'application/json'}, JSON.dump(response)]
      end
    end

    expect(client.get('/account').body).to eq response

    expect(account_headers).to include expected_headers.update(
     'x-amz-date' => '20150101T000000Z',
     'x-amz-security-token' => 'token1420070400',
    )

    expect(account_headers.fetch('authorization')).to match Regexp.new(
      authz_tmpl % {
        access_key_id: 'akid1420070400',
        signature: '93bbcf47fe584eeba8a2cc08e9592e4e0d6367866b0be118b0dcc1b3328f8a2c',
      }
    )

    # 50 minutes after
    Timecop.travel(Time.now + 3000)

    expect(client.get('/account').body).to eq response

    expect(account_headers).to include expected_headers.update(
     'x-amz-date' => '20150101T005000Z',
     'x-amz-security-token' => 'token1420070400',
    )

    expect(account_headers.fetch('authorization')).to match Regexp.new(
      authz_tmpl % {
        access_key_id: 'akid1420070400',
        signature: '03cab6830cb909b4647c34ba24a1932847353a1cf37021dfd629a280c1d0d0ca',
      }
    )

    # 10 minutes after
    Timecop.travel(Time.now + 600)

    expect(client.get('/account').body).to eq response

    expect(account_headers).to include expected_headers.update(
     'x-amz-date' => '20150101T010000Z',
     'x-amz-security-token' => 'token1420074000',
    )

    expect(account_headers.fetch('authorization')).to match Regexp.new(
      authz_tmpl % {
        access_key_id: 'akid1420074000',
        signature: 'f0c3357303f578832e0bc943bce9c2a9040f9c62e8f16bd50e549ced7e3c06e1',
      }
    )
  end
end
