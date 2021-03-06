#!/usr/bin/env perl

# MG-RAST pipeline job submitter for AWE
# Command name: submit_to_awe
# Use case: submit a job with a local input file, existing shock node or copy of existing shock node,
#
#
# example
# ./submit_to_awe2.pl --no_job_id --input_node=154f1536-4248-4fee-a7a7-81fdc60870a0 --no_start --use_ssh --seq_type=WGS --file_format=fastq 2>&1 | tee test.log
# 	--no_job_id if metagenome is not in jobdb


use strict;
use warnings;
no warnings('once');

#use FindBin;
#use local::lib "$FindBin::Bin/../conf";
#use local::lib "$FindBin::Bin/../lib";

use PipelineJob;

use Pipeline_conf_public;
use Pipeline_conf_private;


use JSON;
use Template;
use Getopt::Long;
use LWP::UserAgent;
use HTTP::Request::Common;
use Data::Dumper;


use AWE::Workflow; # includes Shock::Client
use AWE::Client;


use File::Slurp;

# options
my $job_id     = "";
my $no_job_id 	= 0;

my $input_file = ""; # file will be upload
my $copy_node = ""; # existing node will be copied and gets new attributes
my $input_node = ""; # existing node will be used without modification in attributes

my $awe_url    = "";
my $shock_url  = "";

my $clientgroups = undef;
my $seq_type = undef;
my $file_format = undef;
my $no_start   = 0;
my $use_ssh    = 0;

my $help       = 0;
my $pipeline   = "mgrast-test"; # will be overwritten by --production
my $type       = "metagenome-test"; # will be overwritten by --production
my $production = 0; # indicates that this is production

my $options = GetOptions (
        "job_id=s"		=> \$job_id,
		"no_job_id!"	=> \$no_job_id,

        "input_file=s" => \$input_file,
        "copy_node=s" => \$copy_node,
		"input_node=s" => \$input_node,
		"awe_url=s"    => \$awe_url,
		"shock_url=s"  => \$shock_url,

		"no_start!"    => \$no_start,
		"use_ssh!"     => \$use_ssh,

		"clientgroups=s" => \$clientgroups,
		"seq_type=s" => \$seq_type,
		"file_format=s" => \$file_format,

		"pipeline=s"      => \$pipeline,
		"type=s"       => \$type,
		"production!"     => \$production,
		"help!"        => \$help
);

if ($help) {
    print get_usage();
    exit 0;
} elsif (! $job_id && $no_job_id==0) {
    print STDERR "ERROR: A job identifier is required (unless you specify --no_job_id).\n";
    exit 1;
} elsif (! ($input_file || $copy_node || $input_node)) {
    print STDERR "ERROR: An input file or node (copy or input) was not specified.\n";
    exit 1;
} elsif ($input_file && (! -e $input_file)) {
    print STDERR "ERROR: The input file [$input_file] does not exist.\n";
    exit 1;
}


#########################################################


sub submit_workflow {
	my ($workflow, $aweserverurl, $shocktoken, $awetoken) = @_;
	my $debug = 0;
	############################################
	# connect to AWE server and check the clients
	my $awe = new AWE::Client($aweserverurl, $shocktoken, $awetoken, $debug); # second token is for AWE
	unless (defined $awe) {
		die;
	}
	#$awe->checkClientGroup($self->clientgroup)==0 || die "no clients in clientgroup found, ".$self->clientgroup." (AWE server: ".$self->aweserverurl.")";
	print "submit job to AWE server...\n";
	my $json = JSON->new;
	my $submission_result = $awe->submit_job('json_data' => $json->encode($workflow->getHash()));
	unless (defined $submission_result) {
		die "error: submission_result is not defined";
	}
	unless (defined $submission_result->{'data'}) {
		print STDERR Dumper($submission_result);
		exit(1);
	}
	my $awe_job_id = ($submission_result->{'data'}->{'id'} || die "no job_id found");
	print "result from AWE server:\n".$json->pretty->encode( $submission_result )."\n";
	return $awe_job_id;
}


sub read_jobdb {
	
	my ($job_id) = @_;
	
	unless (defined $job_id && length($job_id) > 0) {
		die;
	}
	
	# set obj handles
	my $jobdb=undef;
	#print "PipelineJob::get_jobcache_dbh...\n";
	if ($use_ssh) {
		my $mspath = $ENV{'HOME'}.'/.mysql/';
		$jobdb = PipelineJob::get_jobcache_dbh(
		$Pipeline_conf_private::job_dbhost,
		$Pipeline_conf_private::job_dbname,
		$Pipeline_conf_private::job_dbuser,
		$Pipeline_conf_private::job_dbpass,
		$mspath.'client-key.pem',
		$mspath.'client-cert.pem',
		$mspath.'ca-cert.pem'
		);
	} else {
		$jobdb = PipelineJob::get_jobcache_dbh(
		$Pipeline_conf_private::job_dbhost,
		$Pipeline_conf_private::job_dbname,
		$Pipeline_conf_private::job_dbuser,
		$Pipeline_conf_private::job_dbpass
		);
	}
	
	
	# get job related info from DB
	#print "PipelineJob::get_jobcache_info...\n";
	my $jobj = PipelineJob::get_jobcache_info($jobdb, $job_id);
	unless ($jobj && (scalar(keys %$jobj) > 0) && exists($jobj->{options})) {
		print STDERR "ERROR: Job $job_id does not exist.\n";
		exit 1;
	}
	#print "PipelineJob::get_job_statistics...\n";
	my $jstat = PipelineJob::get_job_statistics($jobdb, $job_id);
	#print "PipelineJob::get_job_attributes...\n";
	my $jattr = PipelineJob::get_job_attributes($jobdb, $job_id);
	my $jopts = {};
	foreach my $opt (split(/\&/, $jobj->{options})) {
		if ($opt =~ /^filter_options=(.*)/) {
			$jopts->{filter_options} = ($1 || 'skip');
		} else {
			my ($k, $v) = split(/=/, $opt);
			$jopts->{$k} = $v;
		}
	}
	
	
	return $jobj, $jstat, $jattr, $jopts;
}



#########################################################

if ($production) {
	
	$pipeline = "mgrast-prod"; # production default
	
	$type = "metagenome"; # production default
	
}



my $tpage = Template->new(ABSOLUTE => 1);
my $agent = LWP::UserAgent->new();
$agent->timeout(3600);
my $json = JSON->new;
$json = $json->utf8();
$json->max_size(0);
$json->allow_nonref;

# get default urls
#my $vars = $PipelineAWE_Conf::template_keywords;

my $vars_pub = $Pipeline_conf_public::template_keywords;
my $vars_priv = $Pipeline_conf_private::template_keywords;

# merge
my $vars = {};
foreach my $key ( keys %$vars_pub ) {
	$vars->{$key} = $vars_pub->{$key};
}
foreach my $key ( keys %$vars_priv ) {
	$vars->{$key} = $vars_priv->{$key};
}

#print Dumper($vars_pub) ."\n";
#print Dumper($vars_priv) ."\n";
#print Dumper($vars) ."\n";
#exit(0);

if ($shock_url) {
    $vars->{shock_url} = $shock_url;
}
if (! $awe_url) {
    $awe_url = $Pipeline_conf_private::awe_url;
}




my $jobj={};
my $jstat={};
my $jattr={};
my $jopts={};

my $statistics = {};

my $file_name = "";
my $node_id = "";


if (defined($input_node) && $job_id eq "" && $no_job_id==0) {
	# try to find job_id
	# data -> attributes -> job_id
	$node_id = $input_node;
	
	my $request = $agent->get(
		$vars->{shock_url}.'/node/'.$input_node,
		'Authorization', 'OAuth '.$Pipeline_conf_private::shock_pipeline_token
	);
	my $response = undef;
	eval {
		$response = $json->decode($request->content);
	};
	if ($@) {
		print STDERR "ERROR: Return from shock is not JSON:\n".$response->content."\n";
		exit 1;
	}
	if ($response->{error}) {
		print STDERR "ERROR: (shock) ".$response->{error}[0]."\n";
		exit 1;
	}
	
	print Dumper($response);
	$job_id = $response->{'data'}->{'attributes'}->{job_id};

	
	unless (defined($job_id) && length($job_id) > 0) {
		die "job_id is empty";
	}
	
	
	$file_name = $response->{'data'}->{'file'}->{'name'};
	unless (defined($file_name) && length($file_name) > 0 ) {
		die "no filename found";
	}
	
	print "read job_id from shock attributes: ".$job_id."\n";
	
}


#read jobdb
if (defined($job_id) && length($job_id) > 0 ) {
	print "read jobdb...\n";
	($jobj, $jstat, $jattr, $jopts)  = read_jobdb($job_id);
	
	foreach my $s (keys %$jstat) {
		if ($s =~ /(.+)_raw$/) {
			$statistics->{$1} = $jstat->{$s};
		}
	}

}


print "populate workflow variables...\n";

# populate workflow variables
$vars->{job_id}         = ($job_id || "0");
$vars->{mg_id}          = 'mgm'.($jobj->{metagenome_id} || ''); #$up_attr->{id};
#$vars->{mg_name}        = $up_attr->{name};
$vars->{job_date}       = ($jobj->{created_on} || ''); #$up_attr->{created};
$vars->{file_format}    = ( $file_format || ($jattr->{file_type} && ($jattr->{file_type} eq 'fastq')) ? 'fastq' : 'fasta' ); #$up_attr->{file_format};
$vars->{seq_type}       = ($seq_type || $jobj->{sequence_type} || $jattr->{sequence_type_guess}|| die "please specify sequence type"); #$up_attr->{sequence_type};
$vars->{bp_count}       = $statistics->{bp_count}; #$up_attr->{statistics}{bp_count};
#$vars->{user}           = 'mgu'.$jobj->{owner} || '';
$vars->{inputfile}      = ($file_name || 'filename');
$vars->{shock_node}     = ($node_id || 'unknown');
$vars->{filter_options} = ($jopts->{filter_options} || 'skip');
$vars->{assembled}      = exists($jattr->{assembled}) ? $jattr->{assembled} : 0;
$vars->{dereplicate}    = exists($jopts->{dereplicate}) ? $jopts->{dereplicate} : 1;
$vars->{bowtie}         = exists($jopts->{bowtie}) ? $jopts->{bowtie} : 1;
$vars->{screen_indexes} = exists($jopts->{screen_indexes}) ? $jopts->{screen_indexes} : 'h_sapiens';

if ($jobj->{project_id} && $jobj->{project_name}) {
	#$up_attr->{project_id}   = 'mgp'.$jobj->{project_id};
	#$up_attr->{project_name} = $jobj->{project_name};
	$vars->{project_id}   = 'mgp'.($jobj->{project_id} || '');
	$vars->{project_name} = ($jobj->{project_name} || '');
}


if (defined $pipeline && $pipeline ne "") {
	$vars->{'pipeline'} = $pipeline;
} else {
	die "template variable \"pipeline\" not defined";
}

if (defined $type && $type ne "") {
	$vars->{'type'} = $type;
} else {
	die "template variable \"type\" not defined";
}


if (defined $clientgroups) {
	$vars->{'clientgroups'} = $clientgroups;
}




# set priority
my $priority_map = {
	"never"       => 1,
	"date"        => 5,
	"6months"     => 10,
	"3months"     => 15,
	"immediately" => 20
};
if ($jattr->{priority} && exists($priority_map->{$jattr->{priority}})) {
	$vars->{priority} = $priority_map->{$jattr->{priority}};
}
# higher priority if smaller data
if (defined $statistics->{bp_count}) {
	if (int($statistics->{bp_count}) < 100000000) {
		$vars->{priority} = 30;
	}
	if (int($statistics->{bp_count}) < 50000000) {
		$vars->{priority} = 40;
	}
	if (int($statistics->{bp_count}) < 10000000) {
		$vars->{priority} = 50;
	}
}

print Dumper($vars)."\n";








$HTTP::Request::Common::DYNAMIC_FILE_UPLOAD = 1;

if (defined $input_node) {
	$node_id = $input_node;
} else {
		
	
	# upload file or create copy of existing node with new attributes

	# build upload attributes
	my $up_attr = {
		id          => $vars->{mg_id},
		job_id      => $vars->{job_id},
		name        => ($jobj->{name} || ''),
		created     => $vars->{job_date}, # $jobj->{created_on} || '',
		status      => 'private',
		assembled   => $jattr->{assembled} ? 'yes' : 'no',
		data_type   => 'sequence',
		seq_format  => 'bp',
		file_format => $vars->{file_format}, #($jattr->{file_type} && ($jattr->{file_type} eq 'fastq')) ? 'fastq' : 'fasta',
		stage_id    => '050',
		stage_name  => 'upload',
		type        => $vars->{'type'},
		statistics  => $statistics,
		sequence_type    => $vars->{seq_type}, #$jobj->{sequence_type} || $jattr->{sequence_type_guess}|| die "sequence type unknown",
		pipeline_version => ($vars->{pipeline_version} || ''),
		project_id		=> $vars->{project_id},
		project_name	=> $vars->{project_name}
	};
	#if ($jobj->{project_id} && $jobj->{project_name}) {
	#    $up_attr->{project_id}   = 'mgp'.$jobj->{project_id};
	#    $up_attr->{project_name} = $jobj->{project_name};
	#}
	
	my $content = {};
	
	if ($input_file) {
		# upload input to shock
		$content = {
			upload     => [$input_file],
			attributes => [undef, "$input_file.json", Content => $json->encode($up_attr)]
		};
	} elsif ($copy_node) {
		# copy input node
		$content = {
			copy_data => $copy_node,
			attributes => [undef, "attr.json", Content => $json->encode($up_attr)]
		};
	} else {
		die;
	}

	# POST to shock
	print "upload input to Shock... ";
	my $spost = $agent->post(
		$vars->{shock_url}.'/node',
		'Authorization', 'OAuth '.$Pipeline_conf_private::shock_pipeline_token,
		'Content_Type', 'multipart/form-data',
		'Content', $content
	);
	my $sres = undef;
	eval {
		$sres = $json->decode($spost->content);
	};
	if ($@) {
		print STDERR "ERROR: Return from shock is not JSON:\n".$spost->content."\n";
		exit 1;
	}
	if ($sres->{error}) {
		print STDERR "ERROR: (shock) ".$sres->{error}[0]."\n";
		exit 1;
	}
	print " ...done.\n";
	
	$node_id = $sres->{data}->{id};
	$file_name = $sres->{data}->{file}->{name};
	print "upload shock node\t$node_id\n";
	
	
}



unless (defined($file_name) ) {
	die;
}


##############################################################################################################


my $workflow_args = {
	"pipeline"		=> $pipeline,
	"name"			=> $vars->{job_id},
	"project"		=> ($vars->{project_name} || ''),
	"user"			=> 'mgu'.($jobj->{owner} || ''),
	"clientgroups"	=> ($vars->{'clientgroups'} || die "clientgroup is not defined"),
	"priority" 		=> ($vars->{priority} || 50),
	"shockhost" 	=> ($vars->{shock_url} || die), # default shock server for output files
	"shocktoken" 	=> ($Pipeline_conf_private::shock_pipeline_token || die),
	"userattr" => {
		"id"				=> $vars->{'mg_id'},
		"job_id"			=> $vars->{'job_id'},
		"name"				=> $vars->{'mg_name'},
		"created"			=> $vars->{'job_date'},
		"status"			=> "private",
		"owner"				=> $vars->{'user'},
		"sequence_type"		=> $vars->{'seq_type'},
		"bp_count"			=> $vars->{'bp_count'},
		"project_id"		=> $vars->{'project_id'},
		"project_name"		=> $vars->{'project_name'},
		"type"				=> $vars->{'type'},
		"pipeline_version"	=> $vars->{'pipeline_version'}
	}
};

print "workflow_args: ".Dumper($workflow_args);

my $workflow = new AWE::Workflow(%$workflow_args);




# using "$last_output" simplifies skipping of tasks
my $last_output = shock_resource($vars->{shock_url}, $node_id, $file_name);



### qc ###
#https://github.com/MG-RAST/Skyport/blob/master/app_definitions/MG-RAST/qc.json

my $task_qc = $workflow->newTask(	'MG-RAST/qc.qc.default',
									shock_resource($vars->{shock_url}, $node_id, $file_name),
									string_resource($vars->{file_format}),
									string_resource($vars->{job_id}),
									string_resource($vars->{assembled}),
									string_resource($vars->{filter_options})
);

$task_qc->userattr(	"stage_id" 		=> "075",
					"stage_name" 	=> "qc"

);




### preprocess (optional, fastq or fasta) ###
#https://github.com/MG-RAST/Skyport/blob/master/app_definitions/MG-RAST/base.json

my $task_preprocess = undef;
if ($vars->{filter_options} ne 'skip' || $vars->{file_format} ne 'fasta') {
	print "preprocess\n";
	
	$task_preprocess = $workflow->newTask(	'MG-RAST/base.preprocess.'.$vars->{file_format},
		shock_resource($vars->{shock_url}, $node_id, $file_name),
		string_resource($vars->{job_id}),
		string_resource($vars->{filter_options})
	);
		
	
	
	$task_preprocess->userattr(
		"stage_id"		=> "100",
		"stage_name"	=> "preprocess",
		"file_format"	=> "fasta",
		"seq_format"	=> "bp"
	);
	
	$last_output = task_resource($task_preprocess->taskid(), 'passed');
}



### dereplicate ###
#https://github.com/MG-RAST/Skyport/blob/master/app_definitions/MG-RAST/base.json
# input must be fasta, not fastq
my $task_dereplicate = undef;
if ($vars->{dereplicate} != 0) {
	print "dereplicate\n";
	
	my $dereplicate_input = $last_output;
	
	
	$task_dereplicate = $workflow->newTask(	'MG-RAST/base.dereplicate.default',
		$dereplicate_input,
		string_resource($vars->{job_id}),
		string_resource($vars->{prefix_length}),
		string_resource($vars->{dereplicate})
	);
	
	$task_dereplicate->userattr(
		"stage_id"		=> "150",
		"stage_name"	=> "dereplication",
		"file_format"	=> "fasta",
		"seq_format"	=> "bp"
	);
	
	$last_output = task_resource($task_dereplicate->taskid(), 'passed');
}


### bowtie_screen ###
my $bowtie_screen_input = undef; # since previous two tasks are optional, figure out the input for this task.

if ($vars->{bowtie} != 0 ) {
	print "bowtie ".$vars->{screen_indexes}."\n";
	
	my @bowtie_index_files=();
	
	# check if index exists
	my $has_index = 0;
	foreach my $idx (split(/,/, $vars->{screen_indexes})) {
		if (exists $Pipeline_conf_public::shock_bowtie_indexes->{$idx}) {
			$has_index = 1;
		}
	}
	if (! $has_index) {
		# just use default
		$vars->{screen_indexes} = 'h_sapiens';
	}
	# build bowtie index list
	my $bowtie_url = ($Pipeline_conf_public::shock_bowtie_url || $vars->{shock_url});
	$vars->{index_download_urls} = "";
	foreach my $idx (split(/,/, $vars->{screen_indexes})) {
		if (exists $Pipeline_conf_public::shock_bowtie_indexes->{$idx}) {
			while (my ($ifile, $inode) = each %{$Pipeline_conf_public::shock_bowtie_indexes->{$idx}}) {
				print "bowtie ".$ifile."\n";
				my $sr = shock_resource( ${bowtie_url} , ${inode}, $ifile );
				$sr->{'cache'} = JSON::true; # this inidicates predata files
				push(@bowtie_index_files, $sr );
			}
		}
	}
	if (@bowtie_index_files == 0 ) {
		die "@bowtie_index_files empty";
	}
	
	
	
	
	
	$bowtie_screen_input = $last_output;
	
	
	my $task_bowtie_screen = $workflow->newTask('MG-RAST/bowtie.bowtie.default',
		$bowtie_screen_input,
		string_resource($vars->{job_id}),
		string_resource($vars->{screen_indexes}),
		string_resource($vars->{bowtie}),
		list_resource(\@bowtie_index_files)
	);

	$task_bowtie_screen->userattr(
		"stage_id"		=> "299",
		"stage_name"	=> "screen",
		"data_type"		=> "sequence",
		"file_format"	=> "fasta",
		"seq_format"	=> "bp"
	);
	
	$last_output = task_resource($task_bowtie_screen->taskid(), 'passed');


}



### diamond ###


my $task_diamond = $workflow->newTask('diamond.search.blastx',
	$last_output,
	$vars->{'m5nr_diamond_resource'} # diamond database for M5NR
);


$task_diamond->userattr(
	"stage_id"		=> "???",
	"stage_name"	=> "diamond",
	"m5nr_sims_version" => "???",
	"data_type"		=> "similarity",
	"file_format"	=> "blast m8",
	"sim_type"		=> "protein"
);


my $diamond_result = task_resource($task_diamond->taskid(), 'result');
$last_output = $diamond_result;





### annotate_sims ###

my $task_annotate_sims = $workflow->newTask('MG-RAST/base.annotate_sims.default',
	$last_output,
	string_resource($vars->{'job_id'}),
	string_resource($vars->{'ach_annotation_ver'}),
	$vars->{'m5nr_annotation_url'}
); # produces 4 output files, sims.filter, expand.protein, expand.lca, expand.ontology





##############################################################################################################



my $wf_hash = $workflow->getHash();


unless (defined $wf_hash->{'shockhost'}) {
	print Dumper($wf_hash)."\n";
	die "shockhost not defined";
}

my $workflow_str = $json->pretty->encode( $wf_hash );
print "AWE workflow:\n".$workflow_str."\n";



#write to file for debugging puposes (first time)
my $workflow_file = $Pipeline_conf_private::temp_dir."/".$vars->{job_id}.".awe_workflow.json";
write_file($workflow_file, $workflow_str);

# transform workflow json string into hash
my $workflow_hash = undef;
eval {
	$workflow_hash = $json->decode($workflow_str);
};
if ($@) {
	my $e = $@;
	print "workflow_str:\n $workflow_str\n";
	print STDERR "ERROR: workflow is not valid json ($e)\n";
	exit 1;
}



# test mode
if (defined($no_start) && $no_start==1) {
    print "workflow\t".$workflow_file."\n";
    exit 0;
}


print "\nsubmiting .....\n";

my $awe_id = submit_workflow($workflow, $awe_url, $Pipeline_conf_private::shock_pipeline_token, $Pipeline_conf_private::awe_pipeline_token);

exit(0);




# get info
#my $awe_id  = $ares->{data}{id};
#my $awe_job = "job_TODO";
#print "awe job (".$ares->{data}{jid}.")\t".$ares->{data}{id}."\n";

sub get_usage {
    return "USAGE: submit_to_awe.pl -job_id=<job identifier> -input_file=<input file> -copy_node=<input shock node> [-awe_url=<awe url> -shock_url=<shock url> -template=<template file> -no_start]\n";
}

# enable hash-resolving in the JSON->encode function
sub TO_JSON { return { %{ shift() } }; }

