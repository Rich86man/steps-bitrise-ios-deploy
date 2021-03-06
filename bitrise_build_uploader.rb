require 'json'
require 'net/http'
require 'uri'
require 'ipa_analyzer'


# ----------------------------
# --- Options

options = {
	build_url: ENV['build_url'],
	api_token: ENV['build_api_token'],
	ipa_path: ENV['ipa_path'],
	notify_user_groups: ENV['notify_user_groups'],
	notify_emails: ENV['notify_email_list'],
	is_enable_public_page: ENV['is_enable_public_page'],
}

puts "Options: #{options}"


# ----------------------------
# --- Formatted Output

$formatted_output_file_path = ENV['BITRISE_STEP_FORMATTED_OUTPUT_FILE_PATH']

def puts_string_to_formatted_output(text)
	puts text

	unless $formatted_output_file_path.nil?
		open($formatted_output_file_path, 'a') { |f|
			f.puts(text)
		}
	end
end

def puts_section_to_formatted_output(section_text)
	puts
	puts section_text
	puts

	unless $formatted_output_file_path.nil?
		open($formatted_output_file_path, 'a') { |f|
			f.puts
			f.puts(section_text)
			f.puts
		}
	end
end


# ----------------------------
# --- Cleanup

def cleanup_before_error_exit(reason_msg=nil)
	puts " [!] Error: #{reason_msg}"
	puts_section_to_formatted_output("## Failed")
	unless reason_msg.nil?
		puts_section_to_formatted_output(reason_msg)
	end
	puts_section_to_formatted_output("Check the Logs for details.")
end


begin
	# - Option checks
	raise "No Build URL provided" unless options[:build_url]
	raise "No Build API Token provided" unless options[:api_token]
	raise "No IPA path provided" unless options[:ipa_path]
	raise "IPA does not exist at the provided path" unless File.exists?(options[:ipa_path])

	CONFIG_artifact_create_url = "#{options[:build_url]}/artifacts.json"

	# - Analyze the IPA / collect infos from IPA
	puts
	puts "=> Analyze the IPA"

	puts_section_to_formatted_output("## Analyzing the IPA")
	parsed_ipa_infos = {
		mobileprovision: nil,
		info_plist: nil
	}
	ipa_analyzer = IpaAnalyzer::Analyzer.new(options[:ipa_path])
	begin
		puts " * Opening the IPA"
		ipa_analyzer.open!

		puts " * Collecting Provisioning Profile information"
		parsed_ipa_infos[:mobileprovision] = ipa_analyzer.collect_provision_info()
		raise "Failed to collect Provisioning Profile information" if parsed_ipa_infos[:mobileprovision].nil?

		puts " * Collecting Info.plist information"
		parsed_ipa_infos[:info_plist] = ipa_analyzer.collect_info_plist_info()
		raise "Failed to collect Info.plist information" if parsed_ipa_infos[:info_plist].nil?
	rescue => ex
		puts
		puts "Failed: #{ex}"
		puts
		raise ex
	ensure
		puts " * Closing the IPA"
		ipa_analyzer.close()
	end
	puts
	puts " (i) Parsed IPA infos:"
	puts parsed_ipa_infos
	puts

	# - Create a Build Artifact on Bitrise
	puts
	puts "=> Create a Build Artifact on Bitrise"

	ipa_file_name = File.basename(options[:ipa_path])

	uri = URI(CONFIG_artifact_create_url)
	raw_resp = Net::HTTP.post_form(uri, {
		'api_token' => options[:api_token],
		'title' => ipa_file_name,
		'filename' => ipa_file_name,
		'artifact_type' => 'ios-ipa'
		})
	puts "* raw_resp: #{raw_resp}"
	unless raw_resp.code == '200'
		raise "Failed to create the Build Artifact on Bitrise - code: #{raw_resp.code}"
	end
	parsed_resp = JSON.parse(raw_resp.body)
	puts "* parsed_resp: #{parsed_resp}"

	unless parsed_resp['error_msg'].nil?
		raise "Failed to create the Build Artifact on Bitrise: #{parsed_resp['error_msg']}"
	end

	upload_url = parsed_resp['upload_url']
	raise "No upload_url provided for the artifact" if upload_url.nil?
	artifact_id = parsed_resp['id']
	raise "No artifact_id provided for the artifact" if artifact_id.nil?

	CONFIG_artifact_finished_url = "#{options[:build_url]}/artifacts/#{artifact_id}/finish_upload.json"

	# - Upload the IPA
	puts
	puts "=> Upload the IPA"

	puts "* upload_url: #{upload_url}"

	unless system("curl --fail --silent -T '#{options[:ipa_path]}' -X PUT '#{upload_url}'")
		raise "Failed to upload the Artifact file"
	end

	# - Finish the Artifact creation and send IPA information
	puts
	puts "=> Finish the Artifact creation and send IPA information"

	ipa_file_size = File.size(options[:ipa_path])
	puts " (i) ipa_file_size: #{ipa_file_size} KB / #{ipa_file_size / 1024.0} MB"

	info_plist_content = parsed_ipa_infos[:info_plist][:content]
	mobileprovision_content = parsed_ipa_infos[:mobileprovision][:content]
	ipa_info_hsh = {
		file_size_bytes: ipa_file_size,
		app_info: {
			app_title: info_plist_content['CFBundleName'],
			bundle_id: info_plist_content['CFBundleIdentifier'],
			version: info_plist_content['CFBundleShortVersionString'],
			build_number: info_plist_content['CFBundleVersion'],
			min_OS_version: info_plist_content['MinimumOSVersion'],
			device_family_list: info_plist_content['UIDeviceFamily'],
		},
		provisioning_info: {
			creation_date: mobileprovision_content['CreationDate'],
			expire_date: mobileprovision_content['ExpirationDate'],
			device_UDID_list: mobileprovision_content['ProvisionedDevices'],
			team_name: mobileprovision_content['TeamName'],
			profile_name: mobileprovision_content['Name'],
			provisions_all_devices: mobileprovision_content['ProvisionsAllDevices'],
		}
	}
	puts
	puts " (i) ipa_info_hsh: #{ipa_info_hsh}"
	puts

	uri = URI(CONFIG_artifact_finished_url)
	puts "* uri: #{uri}"
	if options[:notify_user_groups].to_s == "" or options[:notify_user_groups].to_s == "none"
		options[:notify_user_groups] = ""
	end
	raw_resp = Net::HTTP.post_form(uri, {
		'api_token' => options[:api_token],
		'artifact_info' => JSON.dump(ipa_info_hsh),
		'notify_user_groups' => options[:notify_user_groups],
		'notify_emails' => options[:notify_emails],
		'is_enable_public_page' => options[:is_enable_public_page]
		})
	puts "* raw_resp: #{raw_resp}"
	unless raw_resp.code == '200'
		raise "Failed to send 'finished' to Bitrise - code: #{raw_resp.code}"
	end
	parsed_resp = JSON.parse(raw_resp.body)
	puts "* parsed_resp: #{parsed_resp}"
	unless parsed_resp['status'] == 'ok'
		raise "Failed to send 'finished' to Bitrise"
	end
	# - Success
	puts_section_to_formatted_output("## Success")
	#
	puts_section_to_formatted_output("You can find the Downloadable App on Bitrise, on the [Build's page](#{options[:build_url]})")
  # parsed_resp: {"id"=>11973, "created_at"=>"2015-09-14T22:07:34.353Z", "title"=>"HealthKitDemo.ipa", "artifact_type"=>"ios-ipa", "is_processed"=>true, "artifact_meta"=>{"info_type_id"=>"ios-ipa", "file_size_bytes"=>11855688, "test_device_id_list"=>nil, "is_test_install_enabled"=>true, "install_type"=>"unlimited", "app_info"=>{"app_title"=>"HealthKitDemo", "bundle_id"=>"com.flabe.prosper", "version"=>"1.0", "build_number"=>"280", "min_OS_version"=>"8.1", "device_family_list"=>[1]}, "provisioning_info"=>{"creation_date"=>"2015-08-13T17:28:50+00:00", "expire_date"=>"2016-08-12T17:28:50+00:00", "team_name"=>"FLY LIKE A BEAGLE LLC", "profile_name"=>"Prosper Enterprise", "provisions_all_devices"=>true, "distribution_type"=>"distribution-enterprise"}}, "is_test_install_enabled"=>true, "is_public_page_enabled"=>true, "status"=>"ok", "download_url"=>"https://bitrise-prod-build-storage.s3.amazonaws.com/builds/67dccfb6d9f783f8/artifacts/11973/HealthKitDemo.ipa?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOC7N256G7J2W2TQ%2F20150914%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20150914T220736Z&X-Amz-Expires=43200&X-Amz-SignedHeaders=host&X-Amz-Signature=ec49d1fbd2d7456e513b6647a19553f9988abe318dedba19960bae70b1bbe848", "public_install_page_url"=>"https://www.bitrise.io/artifact/11973/p/63a93efae51a5e6397aaa997233463f0", "pending_notify_users"=>[{"username"=>"rich86man", "email"=>"richardbkirk@gmail.com"}, {"username"=>"gizm0duck", "email"=>"shanewolf@gmail.com"}, {"username"=>"asherhunt", "email"=>"asherhunt@gmail.com"}], "notified_emails"=>nil, "pending_notify_emails"=>["RichardBKirk@gmail.com"]}

  r = HTTParty.post("https://tatiana-chat-api-staging.herokuapp.com/api/v1/build_versions?download_url=#{parsed_resp['download_url']}&build_id=#{parsed_resp['artifact_meta']['app_info']['build_number']}")
  puts_section_to_formatted_output("## Posted To tatiana chat api")
  puts_section_to_formatted_output("## #{r.body}")
    
	if options[:is_enable_public_page] == 'yes'
		public_install_page_url = parsed_resp['public_install_page_url']
		if public_install_page_url.to_s.empty?
			raise "Public Install Page was enabled, but no Public Install Page URL is available!"
		else
			unless system("envman add --key BITRISE_PUBLIC_INSTALL_PAGE_URL --value '#{public_install_page_url}'")
				raise "Failed to export BITRISE_PUBLIC_INSTALL_PAGE_URL"
			end
		end
	else
		puts_section_to_formatted_output("Publis Install Page was disabled, no BITRISE_PUBLIC_INSTALL_PAGE_URL is generated.")
	end
rescue => ex
	cleanup_before_error_exit "#{ex}"
	exit 1
end

exit 0
