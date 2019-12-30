#!/usr/bin/env nextflow

// Copyright (C) 2018 IARC/WHO

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

params.help = null

log.info ""
log.info "-------------------------------------------------------------------------"
log.info "  gatk4-HaplotypeCaller v1: Exact HC GATK4 Best Practices         "
log.info "-------------------------------------------------------------------------"
log.info "Copyright (C) IARC/WHO"
log.info "This program comes with ABSOLUTELY NO WARRANTY; for details see LICENSE"
log.info "This is free software, and you are welcome to redistribute it"
log.info "under certain conditions; see LICENSE for details."
log.info "-------------------------------------------------------------------------"
log.info ""

if (params.help)
{
    log.info "---------------------------------------------------------------------"
    log.info "  USAGE                                                 "
    log.info "---------------------------------------------------------------------"
    log.info ""
    log.info "nextflow run iarcbioinfo/gatk4-HaplotypeCaller-nf [OPTIONS]"
    log.info ""
    log.info "Mandatory arguments:"
    log.info "--input                         BAM FILE                    Aligned BAM file (between quotes for BAMs)"
    log.info "--output_dir                    OUTPUT FOLDER               Output for gVCF file"
    log.info "--ref_fasta                     FASTA FILE                  Reference FASTA file"
    log.info "--gatk_exec                     BIN PATH                    Full path to GATK4 executable"
    log.info "--picard_dir                    BIN DIRECTORY               Directory containing Picard Tools jar file"
    log.info "--interval_list                 INTERVAL_LIST FILE          Interval.list file For target"
    log.info "--scatter_count                 POSITIVE_INTEGER            How many jobs the interval list is split"
    exit 1
}

//
// Parameters Init
//
params.input         = null
params.output_dir    = "."
params.ref_fasta     = null
params.gatk_exec     = null
params.picard_dir    = null
params.interval_list = null
params.scatter_count = 10

//
// Parse Input Parameters
//
bam_ch    = Channel
			.fromPath(params.input)
			.map { file -> tuple(file.baseName, file) }
GATK      = params.gatk_exec
PICARD    = params.picard_dir + "/picard.jar"
ref       = file(params.ref_fasta)
interList = file(params.interval_list)


//
// Process Split Intervals, to scatter the load
//
process SplitIntervals {
	cpus 1
	memory '4 GB' 
	time '1h'

    input:
    file genome from ref
	interList

	output:
	file "scatter/*-scattered.interval_list" into interval_ch
	file "${genome}.fai" into faidx_ch
	file "${genome.baseName}.dict" into dict_ch

	script:
	"""
    samtools faidx ${genome}

    java -jar ${PICARD} \
    CreateSequenceDictionary \
    R=${genome} \
    O=${genome.baseName}.dict

    ${GATK} --java-options "-Xmx4g -Xms4g" \
    SplitIntervals \
		-R ${genome} \
		-L ${interList} \
		--subdivision-mode BALANCING_WITHOUT_INTERVAL_SUBDIVISION \
		--scatter-count ${params.scatter_count} \
		-O scatter
	
	"""
}


//
// Process launching HC
//
process HaplotypeCaller {

	cpus 2 // --native-pair-hmm-threads GATK HC argument is set to 4 by default
	memory '10 GB'
	time '12h'

	tag { bamID+"-"+file(Interval) }
	
    input:
    file genome from ref
    file faidx from faidx_ch
    file dict from dict_ch
	set bamID, file(bam), file(Interval) from bam_ch.spread(interval_ch)

	output:
    set bamID, file("${bamID}.${int_tag}.g.vcf") , file("${bamID}.${int_tag}.g.vcf.idx") into gvcf_ch
	
    script:
	int_tag = Interval.baseName

	"""
    ${GATK} --java-options "-Xmx8g -Xms8g" \
		HaplotypeCaller \
		-R ${genome} \
		-I ${bam} \
		-O ${bamID}.${int_tag}.g.vcf \
		-L ${Interval} \
		-contamination 0 \
		-ERC GVCF		
    """
}	


//
// Process Merge and Sort gVCF
//
process MergeGVCFs {

	cpus 1
	memory '24 GB'
	time '6h'

	tag { bamID }
	
	publishDir params.output_dir, mode: 'copy'

    input:
	set bamID, file (gvcfs), file (gvcfidxs) from gvcf_ch.groupTuple()

	output:
    set bamID, file("${bamID}.g.vcf") , file("${bamID}.g.vcf.idx") into merged_gvcf_ch
	
    script:
	"""
    ${GATK} --java-options "-Xmx24g -Xms24g" \
	SortVcf \
	${gvcfs.collect { "--INPUT $it " }.join()} \
	--OUTPUT ${bamID}.g.vcf

    """
}	


