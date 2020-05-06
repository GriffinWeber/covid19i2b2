--##############################################################################
--### 4CE Phase 1.1
--### Date: May 6, 2020
--### Database: Microsoft SQL Server
--### Data Model: i2b2
--### Created By: Griffin Weber (weber@hms.harvard.edu)
--##############################################################################


--******************************************************************************
--******************************************************************************
--*** Configuration and code mappings (modify for your institution)
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- General settings
--------------------------------------------------------------------------------
create table #config (
	siteid varchar(20), -- Up to 20 letters or numbers, must start with letter, no spaces or special characters.
	include_race bit, -- 1 if your site collects race/ethnicity data; 0 if your site does not collect this.
	race_in_fact_table bit, -- 1 if race in observation_fact.concept_cd; 0 if in patient_dimension.race_cd
	hispanic_in_fact_table bit, -- 1 if Hispanic/Latino in observation_fact.concept_cd; 0 if in patient_dimension.race_cd
	death_data_accurate bit, -- 1 if the patient_dimension.death_date field is populated and is accurate
	code_prefix_icd9cm varchar(50), -- prefix (scheme) used in front of a ICD9CM diagnosis code [required]
	code_prefix_icd10cm varchar(50), -- prefix (scheme) used in front of a ICD10CM diagnosis code [required]
	code_prefix_icd9proc varchar(50), -- prefix (scheme) used in front of a ICD9 procedure code [required]
	code_prefix_icd10pcs varchar(50), -- prefix (scheme) used in front of a ICD10 procedure code [required]
	obfuscation_blur int, -- Add random number +/-blur to each count (0 = no blur)
	obfuscation_small_count_mask int, -- Replace counts less than mask with -99 (0 = no small count masking)
	obfuscation_small_count_delete bit, -- Delete rows with small counts (0 = no, 1 = yes)
	obfuscation_demographics bit, -- Replace combination demographics and total counts with -999 (0 = no, 1 = yes)
	output_as_columns bit, -- Return the data in tables with separate columns per field
	output_as_csv bit -- Return the data in tables with a single column containing comma separated values
)
insert into #config
	select 'YOURSITEID', -- siteid
		1, -- include_race
		0, -- race_in_fact_table
		1, -- hispanic_in_fact_table
		1, -- death_data_accurate
		'DIAG|ICD9:', -- code_prefix_icd9cm
		'DIAG|ICD10:', -- code_prefix_icd10cm
		'PROC|ICD9:', -- code_prefix_icd9proc
		'PROC|ICD10:', -- code_prefix_icd10pcs
		0, -- obfuscation_blur
		10, -- obfuscation_small_count_mask
		0, -- obfuscation_small_count_delete
		0, -- obfuscation_demographics
		0, -- output_as_columns
		1 -- output_as_csv

-- ! If your ICD codes do not start with a prefix (e.g., "ICD:"), then you will
-- ! need to customize the query that populates the #Diagnoses table so that
-- ! only diagnosis codes are selected from the observation_fact table.

--------------------------------------------------------------------------------
-- Code mappings (excluding labs and meds)
-- * Don't change the "code" value.
-- * Modify the "local_code" to match your database.
-- * Repeat a code multiple times if you have more than one local code.
--------------------------------------------------------------------------------
create table #code_map (
	code varchar(50) not null,
	local_code varchar(50) not null
)
alter table #code_map add primary key (code, local_code)
-- Inpatient visits (visit_dimension.inout_cd)
insert into #code_map
	select 'inpatient', 'I'
	union all select 'inpatient', 'IN'
-- Sex (patient_dimension.sex_cd)
insert into #code_map
	select 'male', 'M'
	union all select 'male', 'Male'
	union all select 'female', 'F'
	union all select 'female', 'Female'
-- Race (field based on #config.race_in_fact_table; ignore if you don't collect race/ethnicity)
insert into #code_map
	select 'american_indian', 'NA'
	union all select 'asian', 'A'
	union all select 'asian', 'AS'
	union all select 'black', 'B'
	union all select 'hawaiian_pacific_islander', 'H'
	union all select 'hawaiian_pacific_islander', 'P'
	union all select 'white', 'W'
-- Hispanic/Latino (field based on #config.hispanic_in_fact_table; ignore if you don't collect race/ethnicity)
insert into #code_map
	select 'hispanic_latino', 'DEM|HISP:Y'
	union all select 'hispanic_latino', 'DEM|HISPANIC:Y'
-- Codes that indicate a positive COVID-19 test result (use either option #1 and/or option #2)
-- COVID-19 Positive Option #1: individual concept_cd values
insert into #code_map
	select 'covidpos', 'LOINC:COVID19POS'
-- COVID-19 Positive Option #2: an ontology path (the example here is the COVID ACT "Any Positive Test" path)
insert into #code_map
	select distinct 'covidpos', concept_cd
	from concept_dimension c
	where concept_path like '\ACT\UMLS_C0031437\SNOMED_3947185011\UMLS_C0022885\UMLS_C1335447\%'
		and concept_cd is not null
		and not exists (select * from #code_map m where m.code='covidpos' and m.local_code=c.concept_cd)


--------------------------------------------------------------------------------
-- Lab mappings
-- * Do not change the loinc column or the lab_units column.
-- * Modify the local_code column for the code you use.
-- * Add another row for a lab if you use multiple codes (e.g., see PaO2).
-- * Delete a row if you don't have that lab.
-- * Change the scale_factor if you use different units.
-- * The lab value will be multiplied by the scale_factor
-- *   to convert from your units to the 4CE units.
--------------------------------------------------------------------------------
create table #lab_map (
	loinc varchar(20) not null, 
	local_lab_code varchar(50) not null, 
	scale_factor float, 
	lab_units varchar(20), 
	lab_name varchar(100)
)
alter table #lab_map add primary key (loinc, local_lab_code)
insert into #lab_map
	select loinc, 'LOINC:'+local_lab_code,  -- Change "LOINC:" to your local LOINC code prefix (scheme)
		scale_factor, lab_units, lab_name
	from (
		select '6690-2' loinc, '6690-2' local_lab_code, '1' scale_factor, '10*3/uL' lab_units, 'white blood cell count (Leukocytes)' lab_name
		union select '751-8','751-8','1','10*3/uL','neutrophil count'
		union select '731-0','731-0','1','10*3/uL','lymphocyte count'
		union select '1751-7','1751-7','1','g/dL','albumin'
		union select '2532-0','2532-0','1','U/L','lactate dehydrogenase (LDH)'
		union select '1742-6','1742-6','1','U/L','alanine aminotransferase (ALT)'
		union select '1920-8','1920-8','1','U/L','aspartate aminotransferase (AST)'
		union select '1975-2','1975-2','1','mg/dL','total bilirubin'
		union select '2160-0','2160-0','1','mg/dL','creatinine'
		union select '49563-0','49563-0','1','ng/mL','cardiac troponin (High Sensitivity)'
		union select '6598-7','6598-7','1','ug/L','cardiac troponin (Normal Sensitivity)'
		union select '48065-7','48065-7','1','ng/mL{FEU}','D-dimer (FEU)'
		union select '48066-5','48066-5','1','ng/mL{DDU}','D-dimer (DDU)'
		union select '5902-2','5902-2','1','s','prothrombin time (PT)'
		union select '33959-8','33959-8','1','ng/mL','procalcitonin'
		union select '1988-5','1988-5','1','mg/L','C-reactive protein (CRP) (Normal Sensitivity)'
		union select '3255-7','3255-7','1','mg/dL','Fibrinogen'
		union select '2276-4','2276-4','1','ng/mL','Ferritin'
		union select '2019-8','2019-8','1','mmHg','PaCO2'
		union select '2703-7','2703-7','1','mmHg','PaO2'
		--union select '2703-7','second-code','1','mmHg','PaO2'
		--union select '2703-7','third-code','1','mmHg','PaO2'
	) t

-- Use the concept_dimension to get an expanded list of local lab codes (optional).
-- Uncomment the query below to run this as part of the script.
-- This will pull in additional labs based on your existing mappings.
-- It will find paths corresponding to concepts already in the #lab_map table,
--   and then find all the concepts corresponding to child paths.
-- NOTE: Make sure to adjust the scale_factor if any of these additional
--   lab codes use different units than their parent code.
-- WARNING: This query might take several minutes to run.
/*
insert into #lab_map
	select distinct l.loinc, d.concept_cd, l.scale_factor, l.lab_units, l.lab_name
	from #lab_map l
		inner join concept_dimension c
			on l.local_lab_code = c.concept_cd
		inner join concept_dimension d
			on d.concept_path like c.concept_path+'%'
	where not exists (
		select *
		from #lab_map t
		where t.loinc = l.loinc and t.local_lab_code = d.concept_cd
	)
*/

--------------------------------------------------------------------------------
-- Medication mappings
-- * Do not change the med_class or add additional medications.
-- * The ATC and RxNorm codes represent the same list of medications.
-- * Use ATC and/or RxNorm, depending on what your institution uses.
--------------------------------------------------------------------------------
create table #med_map (
	med_class varchar(50) not null,
	code_type varchar(10) not null,
	local_med_code varchar(50) not null
)
alter table #med_map add primary key (med_class, code_type, local_med_code)

-- ATC codes (optional)
insert into #med_map
	select m, 'ATC' t, 'ATC:'+c  -- Change "ATC:" to your local ATC code prefix (scheme)
	from (
		-- Don't add or remove drugs
		select 'ACEI' m, c from (select 'C09AA01' c union select 'C09AA02' union select 'C09AA03' union select 'C09AA04' union select 'C09AA05' union select 'C09AA06' union select 'C09AA07' union select 'C09AA08' union select 'C09AA09' union select 'C09AA10' union select 'C09AA11' union select 'C09AA13' union select 'C09AA15' union select 'C09AA16') t
		union select 'ARB', c from (select 'C09CA01' c union select 'C09CA02' union select 'C09CA03' union select 'C09CA04' union select 'C09CA06' union select 'C09CA07' union select 'C09CA08') t
		union select 'COAGA', c from (select 'B01AC04' c union select 'B01AC05' union select 'B01AC07' union select 'B01AC10' union select 'B01AC13' union select 'B01AC16' union select 'B01AC17' union select 'B01AC22' union select 'B01AC24' union select 'B01AC25' union select 'B01AC26') t
		union select 'COAGB', c from (select 'B01AA01' c union select 'B01AA03' union select 'B01AA04' union select 'B01AA07' union select 'B01AA11' union select 'B01AB01' union select 'B01AB04' union select 'B01AB05' union select 'B01AB06' union select 'B01AB07' union select 'B01AB08' union select 'B01AB10' union select 'B01AB12' union select 'B01AE01' union select 'B01AE02' union select 'B01AE03' union select 'B01AE06' union select 'B01AE07' union select 'B01AF01' union select 'B01AF02' union select 'B01AF03' union select 'B01AF04' union select 'B01AX05' union select 'B01AX07') t
		union select 'COVIDVIRAL', c from (select 'J05AE10' c union select 'J05AP01' union select 'J05AR10') t
		union select 'DIURETIC', c from (select 'C03CA01' c union select 'C03CA02' union select 'C03CA03' union select 'C03CA04' union select 'C03CB01' union select 'C03CB02' union select 'C03CC01') t
		union select 'HCQ', c from (select 'P01BA01' c union select 'P01BA02') t
		union select 'ILI', c from (select 'L04AC03' c union select 'L04AC07' union select 'L04AC11' union select 'L04AC14') t
		union select 'INTERFERON', c from (select 'L03AB08' c union select 'L03AB11') t
		union select 'SIANES', c from (select 'M03AC03' c union select 'M03AC09' union select 'M03AC11' union select 'N01AX03' union select 'N01AX10' union select 'N05CD08' union select 'N05CM18') t
		union select 'SICARDIAC', c from (select 'B01AC09' c union select 'C01CA03' union select 'C01CA04' union select 'C01CA06' union select 'C01CA07' union select 'C01CA24' union select 'C01CE02' union select 'C01CX09' union select 'H01BA01' union select 'R07AX01') t
	) t

-- RxNorm codes (optional)
insert into #med_map
	select m, 'RxNorm' t, 'RxNorm:'+c  -- Change "RxNorm:" to your local RxNorm code prefix (scheme)
	from (
		-- Don't add or remove drugs
		select 'ACEI' m, c from (select '36908' c union select '39990' union select '104375' union select '104376' union select '104377' union select '104378' union select '104383' union select '104384' union select '104385' union select '1299896' union select '1299897' union select '1299963' union select '1299965' union select '1435623' union select '1435624' union select '1435630' union select '1806883' union select '1806884' union select '1806890' union select '18867' union select '197884' union select '198187' union select '198188' union select '198189' union select '199351' union select '199352' union select '199353' union select '199622' union select '199707' union select '199708' union select '199709' union select '1998' union select '199816' union select '199817' union select '199931' union select '199937' union select '205326' union select '205707' union select '205778' union select '205779' union select '205780' union select '205781' union select '206277' union select '206313' union select '206764' union select '206765' union select '206766' union select '206771' union select '207780' union select '207792' union select '207800' union select '207820' union select '207891' union select '207892' union select '207893' union select '207895' union select '210671' union select '210672' union select '210673' union select '21102' union select '211535' union select '213482' union select '247516' union select '251856' union select '251857' union select '260333' union select '261257' union select '261258' union select '261962' union select '262076' union select '29046' union select '30131' union select '308607' union select '308609' union select '308612' union select '308613' union select '308962' union select '308963' union select '308964' union select '310063' union select '310065' union select '310066' union select '310067' union select '310422' union select '311353' union select '311354' union select '311734' union select '311735' union select '312311' union select '312312' union select '312313' union select '312748' union select '312749' union select '312750' union select '313982' union select '313987' union select '314076' union select '314077' union select '314203' union select '317173' union select '346568' union select '347739' union select '347972' union select '348000' union select '35208' union select '35296' union select '371001' union select '371254' union select '371506' union select '372007' union select '372274' union select '372614' union select '372945' union select '373293' union select '373731' union select '373748' union select '373749' union select '374176' union select '374177' union select '374938' union select '378288' union select '3827' union select '38454' union select '389182' union select '389183' union select '389184' union select '393442' union select '401965' union select '401968' union select '411434' union select '50166' union select '542702' union select '542704' union select '54552' union select '60245' union select '629055' union select '656757' union select '807349' union select '845488' union select '845489' union select '854925' union select '854927' union select '854984' union select '854986' union select '854988' union select '854990' union select '857169' union select '857171' union select '857183' union select '857187' union select '857189' union select '858804' union select '858806' union select '858810' union select '858812' union select '858813' union select '858815' union select '858817' union select '858819' union select '858821' union select '898687' union select '898689' union select '898690' union select '898692' union select '898719' union select '898721' union select '898723' union select '898725') t
		union select 'ARB', c from (select '118463' c union select '108725' union select '153077' union select '153665' union select '153666' union select '153667' union select '153821' union select '153822' union select '153823' union select '153824' union select '1996253' union select '1996254' union select '199850' union select '199919' union select '200094' union select '200095' union select '200096' union select '205279' union select '205304' union select '205305' union select '2057151' union select '2057152' union select '2057158' union select '206256' union select '213431' union select '213432' union select '214354' union select '261209' union select '261301' union select '282755' union select '284531' union select '310139' union select '310140' union select '311379' union select '311380' union select '314073' union select '349199' union select '349200' union select '349201' union select '349483' union select '351761' union select '351762' union select '352001' union select '352274' union select '370704' union select '371247' union select '372651' union select '374024' union select '374279' union select '374612' union select '378276' union select '389185' union select '484824' union select '484828' union select '484855' union select '52175' union select '577776' union select '577785' union select '577787' union select '598024' union select '615856' union select '639536' union select '639537' union select '639539' union select '639543' union select '69749' union select '73494' union select '83515' union select '83818' union select '979480' union select '979482' union select '979485' union select '979487' union select '979492' union select '979494') t
		union select 'COAGA', c from (select '27518' c union select '10594' union select '108911' union select '1116632' union select '1116634' union select '1116635' union select '1116639' union select '1537034' union select '1537038' union select '1537039' union select '1537045' union select '1656052' union select '1656055' union select '1656056' union select '1656061' union select '1656683' union select '1666332' union select '1666334' union select '1736469' union select '1736470' union select '1736472' union select '1736477' union select '1736478' union select '1737465' union select '1737466' union select '1737468' union select '1737471' union select '1737472' union select '1812189' union select '1813035' union select '1813037' union select '197622' union select '199314' union select '200348' union select '200349' union select '205253' union select '206714' union select '207569' union select '208316' union select '208558' union select '213169' union select '213299' union select '241162' union select '261096' union select '261097' union select '309362' union select '309952' union select '309953' union select '309955' union select '313406' union select '32968' union select '333833' union select '3521' union select '371917' union select '374131' union select '374583' union select '375035' union select '392451' union select '393522' union select '613391' union select '73137' union select '749196' union select '749198' union select '75635' union select '83929' union select '855811' union select '855812' union select '855816' union select '855818' union select '855820') t
		union select 'COAGB', c from (select '2110605' c union select '237057' union select '69528' union select '8150' union select '163426' union select '1037042' union select '1037044' union select '1037045' union select '1037049' union select '1037179' union select '1037181' union select '1110708' union select '1114195' union select '1114197' union select '1114198' union select '1114202' union select '11289' union select '114934' union select '1232082' union select '1232084' union select '1232086' union select '1232088' union select '1241815' union select '1241823' union select '1245458' union select '1245688' union select '1313142' union select '1359733' union select '1359900' union select '1359967' union select '1360012' union select '1360432' union select '1361029' union select '1361038' union select '1361048' union select '1361226' union select '1361568' union select '1361574' union select '1361577' union select '1361607' union select '1361613' union select '1361615' union select '1361853' union select '1362024' union select '1362026' union select '1362027' union select '1362029' union select '1362030' union select '1362048' union select '1362052' union select '1362054' union select '1362055' union select '1362057' union select '1362059' union select '1362060' union select '1362061' union select '1362062' union select '1362063' union select '1362065' union select '1362067' union select '1362824' union select '1362831' union select '1362837' union select '1362935' union select '1362962' union select '1364430' union select '1364434' union select '1364435' union select '1364441' union select '1364445' union select '1364447' union select '1490491' union select '1490493' union select '15202' union select '152604' union select '154' union select '1549682' union select '1549683' union select '1598' union select '1599538' union select '1599542' union select '1599543' union select '1599549' union select '1599551' union select '1599553' union select '1599555' union select '1599557' union select '1656595' union select '1656599' union select '1656760' union select '1657991' union select '1658634' union select '1658637' union select '1658647' union select '1658659' union select '1658690' union select '1658692' union select '1658707' union select '1658717' union select '1658719' union select '1658720' union select '1659195' union select '1659197' union select '1659260' union select '1659263' union select '1723476' union select '1723478' union select '1798389' union select '1804730' union select '1804735' union select '1804737' union select '1804738' union select '1807809' union select '1856275' union select '1856278' union select '1857598' union select '1857949' union select '1927851' union select '1927855' union select '1927856' union select '1927862' union select '1927864' union select '1927866' union select '197597' union select '198349' union select '1992427' union select '1992428' union select '1997015' union select '1997017' union select '204429' union select '204431' union select '205791' union select '2059015' union select '2059017' union select '209081' union select '209082' union select '209083' union select '209084' union select '209086' union select '209087' union select '209088' union select '211763' union select '212123' union select '212124' union select '212155' union select '238722' union select '238727' union select '238729' union select '238730' union select '241112' union select '241113' union select '242501' union select '244230' union select '244231' union select '244239' union select '244240' union select '246018' union select '246019' union select '248140' union select '248141' union select '251272' union select '280611' union select '282479' union select '283855' union select '284458' union select '284534' union select '308351' union select '308769' union select '310710' union select '310713' union select '310723' union select '310732' union select '310733' union select '310734' union select '310739' union select '310741' union select '313410' union select '313732' union select '313733' union select '313734' union select '313735' union select '313737' union select '313738' union select '313739' union select '314013' union select '314279' union select '314280' union select '321208' union select '349308' union select '351111' union select '352081' union select '352102' union select '370743' union select '371679' union select '371810' union select '372012' union select '374319' union select '374320' union select '374638' union select '376834' union select '381158' union select '389189' union select '402248' union select '402249' union select '404141' union select '404142' union select '404143' union select '404144' union select '404146' union select '404147' union select '404148' union select '404259' union select '404260' union select '415379' union select '5224' union select '540217' union select '542824' union select '545076' union select '562130' union select '562550' union select '581236' union select '60819' union select '616862' union select '616912' union select '645887' union select '67031' union select '67108' union select '67109' union select '69646' union select '727382' union select '727383' union select '727384' union select '727559' union select '727560' union select '727562' union select '727563' union select '727564' union select '727565' union select '727566' union select '727567' union select '727568' union select '727718' union select '727719' union select '727722' union select '727723' union select '727724' union select '727725' union select '727726' union select '727727' union select '727728' union select '727729' union select '727730' union select '727778' union select '727831' union select '727832' union select '727834' union select '727838' union select '727851' union select '727859' union select '727860' union select '727861' union select '727878' union select '727880' union select '727881' union select '727882' union select '727883' union select '727884' union select '727888' union select '727892' union select '727920' union select '727922' union select '727926' union select '729968' union select '729969' union select '729970' union select '729971' union select '729972' union select '729973' union select '729974' union select '729976' union select '730002' union select '746573' union select '746574' union select '753111' union select '753112' union select '753113' union select '759595' union select '759596' union select '759597' union select '759598' union select '759599' union select '75960' union select '759600' union select '759601' union select '792060' union select '795798' union select '827000' union select '827001' union select '827003' union select '827069' union select '827099' union select '829884' union select '829885' union select '829886' union select '829888' union select '830698' union select '848335' union select '848339' union select '849297' union select '849298' union select '849299' union select '849300' union select '849301' union select '849312' union select '849313' union select '849317' union select '849333' union select '849337' union select '849338' union select '849339' union select '849340' union select '849341' union select '849342' union select '849344' union select '849699' union select '849702' union select '849710' union select '849712' union select '849715' union select '849718' union select '849722' union select '849726' union select '849764' union select '849770' union select '849776' union select '849814' union select '854228' union select '854232' union select '854235' union select '854236' union select '854238' union select '854239' union select '854241' union select '854242' union select '854245' union select '854247' union select '854248' union select '854249' union select '854252' union select '854253' union select '854255' union select '854256' union select '855288' union select '855290' union select '855292' union select '855296' union select '855298' union select '855300' union select '855302' union select '855304' union select '855306' union select '855308' union select '855312' union select '855314' union select '855316' union select '855318' union select '855320' union select '855322' union select '855324' union select '855326' union select '855328' union select '855332' union select '855334' union select '855336' union select '855338' union select '855340' union select '855342' union select '855344' union select '855346' union select '855348' union select '855350' union select '857253' union select '857255' union select '857257' union select '857259' union select '857261' union select '857645' union select '861356' union select '861358' union select '861360' union select '861362' union select '861363' union select '861364' union select '861365' union select '861366' union select '978713' union select '978715' union select '978717' union select '978718' union select '978719' union select '978720' union select '978721' union select '978722' union select '978723' union select '978725' union select '978727' union select '978733' union select '978735' union select '978736' union select '978737' union select '978738' union select '978740' union select '978741' union select '978744' union select '978745' union select '978746' union select '978747' union select '978755' union select '978757' union select '978759' union select '978761' union select '978777' union select '978778') t
		union select 'COVIDVIRAL', c from (select '108766' c union select '1236627' union select '1236628' union select '1236632' union select '1298334' union select '1359269' union select '1359271' union select '1486197' union select '1486198' union select '1486200' union select '1486202' union select '1486203' union select '1487498' union select '1487500' union select '1863148' union select '1992160' union select '207406' union select '248109' union select '248110' union select '248112' union select '284477' union select '284640' union select '311368' union select '311369' union select '312817' union select '312818' union select '352007' union select '352337' union select '373772' union select '373773' union select '373774' union select '374642' union select '374643' union select '376293' union select '378671' union select '460132' union select '539485' union select '544400' union select '597718' union select '597722' union select '597729' union select '597730' union select '602770' union select '616129' union select '616131' union select '616133' union select '643073' union select '643074' union select '670026' union select '701411' union select '701413' union select '746645' union select '746647' union select '754738' union select '757597' union select '757598' union select '757599' union select '757600' union select '790286' union select '794610' union select '795742' union select '795743' union select '824338' union select '824876' union select '831868' union select '831870' union select '847330' union select '847741' union select '847745' union select '847749' union select '850455' union select '850457' union select '896790' union select '902312' union select '902313' union select '9344') t
		union select 'DIURETIC', c from (select '392534' c union select '4109' union select '392464' union select '33770' union select '104220' union select '104222' union select '1112201' union select '132604' union select '1488537' union select '1546054' union select '1546056' union select '1719285' union select '1719286' union select '1719290' union select '1719291' union select '1727568' union select '1727569' union select '1727572' union select '1729520' union select '1729521' union select '1729523' union select '1729527' union select '1729528' union select '1808' union select '197417' union select '197418' union select '197419' union select '197730' union select '197731' union select '197732' union select '198369' union select '198370' union select '198371' union select '198372' union select '199610' union select '200801' union select '200809' union select '204154' union select '205488' union select '205489' union select '205490' union select '205732' union select '208076' union select '208078' union select '208080' union select '208081' union select '208082' union select '248657' union select '250044' union select '250660' union select '251308' union select '252484' union select '282452' union select '282486' union select '310429' union select '313988' union select '371157' union select '371158' union select '372280' union select '372281' union select '374168' union select '374368' union select '38413' union select '404018' union select '4603' union select '545041' union select '561969' union select '630032' union select '630035' union select '645036' union select '727573' union select '727574' union select '727575' union select '727845' union select '876422' union select '95600') t
		union select 'HCQ', c from (select '1116758' c union select '1116760' union select '1117346' union select '1117351' union select '1117353' union select '1117531' union select '197474' union select '197796' union select '202317' union select '213378' union select '226388' union select '2393' union select '249663' union select '250175' union select '261104' union select '370656' union select '371407' union select '5521' union select '755624' union select '755625' union select '756408' union select '979092' union select '979094') t
		union select 'ILI', c from (select '1441526' c union select '1441527' union select '1441530' union select '1535218' union select '1535242' union select '1535247' union select '1657973' union select '1657974' union select '1657976' union select '1657979' union select '1657980' union select '1657981' union select '1657982' union select '1658131' union select '1658132' union select '1658135' union select '1658139' union select '1658141' union select '1923319' union select '1923332' union select '1923333' union select '1923338' union select '1923345' union select '1923347' union select '2003754' union select '2003755' union select '2003757' union select '2003766' union select '2003767' union select '351141' union select '352056' union select '612865' union select '72435' union select '727708' union select '727711' union select '727714' union select '727715' union select '895760' union select '895764') t
		union select 'INTERFERON', c from (select '120608' c union select '1650893' union select '1650894' union select '1650896' union select '1650922' union select '1650940' union select '1651307' union select '1721323' union select '198360' union select '207059' union select '351270' union select '352297' union select '378926' union select '403986' union select '72257' union select '731325' union select '731326' union select '731328' union select '731330' union select '860244') t
		union select 'SIANES', c from (select '106517' c union select '1087926' union select '1188478' union select '1234995' union select '1242617' union select '1249681' union select '1301259' union select '1313988' union select '1373737' union select '1486837' union select '1535224' union select '1535226' union select '1535228' union select '1535230' union select '1551393' union select '1551395' union select '1605773' union select '1666776' union select '1666777' union select '1666797' union select '1666798' union select '1666800' union select '1666814' union select '1666821' union select '1666823' union select '1718899' union select '1718900' union select '1718902' union select '1718906' union select '1718907' union select '1718909' union select '1718910' union select '1730193' union select '1730194' union select '1730196' union select '1732667' union select '1732668' union select '1732674' union select '1788947' union select '1808216' union select '1808217' union select '1808219' union select '1808222' union select '1808223' union select '1808224' union select '1808225' union select '1808234' union select '1808235' union select '1862110' union select '198383' union select '199211' union select '199212' union select '199775' union select '2050125' union select '2057964' union select '206967' union select '206970' union select '206972' union select '207793' union select '207901' union select '210676' union select '210677' union select '238082' union select '238083' union select '238084' union select '240606' union select '259859' union select '284397' union select '309710' union select '311700' union select '311701' union select '311702' union select '312674' union select '319864' union select '372528' union select '372922' union select '375623' union select '376856' union select '377135' union select '377219' union select '377483' union select '379133' union select '404091' union select '404092' union select '404136' union select '422410' union select '446503' union select '48937' union select '584528' union select '584530' union select '6130' union select '631205' union select '68139' union select '6960' union select '71535' union select '828589' union select '828591' union select '830752' union select '859437' union select '8782' union select '884675' union select '897073' union select '897077' union select '998210' union select '998211') t
		union select 'SICARDIAC', c from (select '7442' c union select '1009216' union select '1045470' union select '1049182' union select '1049184' union select '1052767' union select '106686' union select '106779' union select '106780' union select '1087043' union select '1087047' union select '1090087' union select '1114874' union select '1114880' union select '1114888' union select '11149' union select '1117374' union select '1232651' union select '1232653' union select '1234563' union select '1234569' union select '1234571' union select '1234576' union select '1234578' union select '1234579' union select '1234581' union select '1234584' union select '1234585' union select '1234586' union select '1251018' union select '1251022' union select '1292716' union select '1292731' union select '1292740' union select '1292751' union select '1292887' union select '1299137' union select '1299141' union select '1299145' union select '1299879' union select '1300092' union select '1302755' union select '1305268' union select '1305269' union select '1307224' union select '1358843' union select '1363777' union select '1363785' union select '1363786' union select '1363787' union select '1366958' union select '141848' union select '1490057' union select '1542385' union select '1546216' union select '1546217' union select '1547926' union select '1548673' union select '1549386' union select '1549388' union select '1593738' union select '1658178' union select '1660013' union select '1660014' union select '1660016' union select '1661387' union select '1666371' union select '1666372' union select '1666374' union select '1721536' union select '1743862' union select '1743869' union select '1743871' union select '1743877' union select '1743879' union select '1743938' union select '1743941' union select '1743950' union select '1743953' union select '1745276' union select '1789858' union select '1791839' union select '1791840' union select '1791842' union select '1791854' union select '1791859' union select '1791861' union select '1812167' union select '1812168' union select '1812170' union select '1870205' union select '1870207' union select '1870225' union select '1870230' union select '1870232' union select '1939322' union select '198620' union select '198621' union select '198786' union select '198787' union select '198788' union select '1989112' union select '1989117' union select '1991328' union select '1991329' union select '1999003' union select '1999006' union select '1999007' union select '1999012' union select '204395' union select '204843' union select '209217' union select '2103181' union select '2103182' union select '2103184' union select '211199' union select '211200' union select '211704' union select '211709' union select '211712' union select '211714' union select '211715' union select '212343' union select '212770' union select '212771' union select '212772' union select '212773' union select '238217' union select '238218' union select '238219' union select '238230' union select '238996' union select '238997' union select '238999' union select '239000' union select '239001' union select '241033' union select '242969' union select '244284' union select '245317' union select '247596' union select '247940' union select '260687' union select '309985' union select '309986' union select '309987' union select '310011' union select '310012' union select '310013' union select '310116' union select '310117' union select '310127' union select '310132' union select '311705' union select '312395' union select '312398' union select '313578' union select '313967' union select '314175' union select '347930' union select '351701' union select '351702' union select '351982' union select '359907' union select '3616' union select '3628' union select '372029' union select '372030' union select '372031' union select '373368' union select '373369' union select '373370' union select '373372' union select '373375' union select '374283' union select '374570' union select '376521' union select '377281' union select '379042' union select '387789' union select '392099' union select '393309' union select '3992' union select '404093' union select '477358' union select '477359' union select '52769' union select '542391' union select '542655' union select '542674' union select '562501' union select '562502' union select '562592' union select '584580' union select '584582' union select '584584' union select '584588' union select '602511' union select '603259' union select '603276' union select '603915' union select '617785' union select '669267' union select '672683' union select '672685' union select '672891' union select '692479' union select '700414' union select '704955' union select '705163' union select '705164' union select '705170' union select '727310' union select '727316' union select '727345' union select '727347' union select '727373' union select '727386' union select '727410' union select '727842' union select '727843' union select '727844' union select '746206' union select '746207' union select '7512' union select '8163' union select '827706' union select '864089' union select '880658' union select '8814' union select '883806' union select '891437' union select '891438') t
	) t

-- Remdesivir defined separately since many sites will have custom codes (optional)
insert into #med_map
	select 'REMDESIVIR', 'RxNorm', 'RxNorm:2284718'
	union select 'REMDESIVIR', 'RxNorm', 'RxNorm:2284960'
	union select 'REMDESIVIR', 'Custom', 'ACT|LOCAL:REMDESIVIR'


-- Use the concept_dimension to get an expanded list of medication codes (optional)
-- Uncomment the query below to run this as part of the script.
-- Change "\ACT\Medications\%" to the root path of medications in your ontology.
-- This will pull in additional medications based on your existing mappings.
-- It will find paths corresponding to concepts already in the #med_map table,
--   and then find all the concepts corresponding to child paths.
-- WARNING: This query might take several minutes to run. If it is taking more
--   than an hour, then stop the query and contact us about alternative approaches.
/*
select concept_path, concept_cd
	into #med_paths
	from concept_dimension
	where concept_path like '\ACT\Medications\%'
		and concept_cd in (select concept_cd from observation_fact) 
alter table #med_paths add primary key (concept_path)
insert into #med_map
	select distinct m.med_class, 'Expand', d.concept_cd
	from #med_map m
		inner join concept_dimension c
			on m.local_med_code = c.concept_cd
		inner join #med_paths d
			on d.concept_path like c.concept_path+'%'
	where not exists (
		select *
		from #med_map t
		where t.med_class = m.med_class and t.local_med_code = d.concept_cd
	)
*/



--##############################################################################
--### Most sites will not have to modify any SQL beyond this point.
--### However, review the queries to see if you need to customize them
--###   for special logic, privacy, etc.
--##############################################################################



--******************************************************************************
--******************************************************************************
--*** Define the COVID cohort (COVID postive test + admitted)
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- Create the list of COVID-19 positive patients.
-- Use the earliest date where the patient is known to be COVID positive,
--   for example, a COVID positive test result.
--------------------------------------------------------------------------------
create table #covid_pos_patients (
	patient_num int not null,
	covid_pos_date date not null
)
alter table #covid_pos_patients add primary key (patient_num, covid_pos_date)
insert into #covid_pos_patients
	select patient_num, cast(min(start_date) as date) covid_pos_date
	from observation_fact f
		inner join #code_map m
			on f.concept_cd = m.local_code and m.code = 'covidpos'
	group by patient_num

--------------------------------------------------------------------------------
-- Create a list of dates when patients were inpatient starting one week  
--   before their COVID pos date.
--------------------------------------------------------------------------------
create table #admissions (
	patient_num int not null,
	admission_date date not null,
	discharge_date date not null
)
alter table #admissions add primary key (patient_num, admission_date, discharge_date)
insert into #admissions
	select distinct v.patient_num, cast(start_date as date), cast(isnull(end_date,GetDate()) as date)
	from visit_dimension v
		inner join #covid_pos_patients p
			on v.patient_num=p.patient_num 
				and v.start_date >= dateadd(dd,-7,p.covid_pos_date)
		inner join #code_map m
			on v.inout_cd = m.local_code and m.code = 'inpatient'

--------------------------------------------------------------------------------
-- Get the list of patients who will be the covid cohort.
-- These will be patients who had an admission between 7 days before and
--   14 days after their covid positive test date.
--------------------------------------------------------------------------------
create table #covid_cohort (
	patient_num int not null,
	admission_date date,
	severe int,
	severe_date date,
	death_date date
)
alter table #covid_cohort add primary key (patient_num)
insert into #covid_cohort
	select p.patient_num, min(admission_date) admission_date, 0, null, null
	from #covid_pos_patients p
		inner join #admissions a
			on p.patient_num = a.patient_num	
				and a.admission_date <= dateadd(dd,14,covid_pos_date)
	group by p.patient_num


--******************************************************************************
--******************************************************************************
--*** Determine which patients had severe disease or died
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- Flag the patients who had severe disease anytime since admission.
--------------------------------------------------------------------------------
create table #severe_patients (
	patient_num int not null,
	severe_date date
)
-- Get a list of patients with severe codes
-- WARNING: This query might take a few minutes to run.
insert into #severe_patients
	select f.patient_num, min(start_date) start_date
	from observation_fact f
		inner join #covid_cohort c
			on f.patient_num = c.patient_num and f.start_date >= c.admission_date
		cross apply #config x
	where 
		-- Any PaCO2 or PaO2 lab test
		f.concept_cd in (select local_lab_code from #lab_map where loinc in ('2019-8','2703-7'))
		-- Any severe medication
		or f.concept_cd in (select local_med_code from #med_map where med_class in ('SIANES','SICARDIAC'))
		-- Acute respiratory distress syndrome (diagnosis)
		or f.concept_cd in (code_prefix_icd10cm+'J80', code_prefix_icd9cm+'518.82')
		-- Ventilator associated pneumonia (diagnosis)
		or f.concept_cd in (code_prefix_icd10cm+'J95.851', code_prefix_icd9cm+'997.31')
		-- Insertion of endotracheal tube (procedure)
		or f.concept_cd in (code_prefix_icd10pcs+'0BH17EZ', code_prefix_icd9proc+'96.04')
		-- Invasive mechanical ventilation (procedure)
		or f.concept_cd like code_prefix_icd10pcs+'5A09[345]%'
		or f.concept_cd like code_prefix_icd9proc+'96.7[012]'
	group by f.patient_num
-- Update the covid_cohort table to flag severe patients 
update c
	set c.severe = 1, c.severe_date = s.severe_date
	from #covid_cohort c
		inner join (
			select patient_num, min(severe_date) severe_date
			from #severe_patients
			group by patient_num
		) s on c.patient_num = s.patient_num

--------------------------------------------------------------------------------
-- Add death dates to patients who have died.
--------------------------------------------------------------------------------
if exists (select * from #config where death_data_accurate = 1)
begin
	-- Get the death date from the patient_dimension table.
	update c
		set c.death_date = (
			case when p.death_date > isnull(severe_date,admission_date) 
			then p.death_date 
			else isnull(severe_date,admission_date) end)
		from #covid_cohort c
			inner join patient_dimension p
				on p.patient_num = c.patient_num
		where p.death_date is not null or p.vital_status_cd in ('Y')
	-- Check that there aren't more recent facts for the deceased patients.
	update c
		set c.death_date = d.death_date
		from #covid_cohort c
			inner join (
				select p.patient_num, max(f.start_date) death_date
				from #covid_cohort p
					inner join observation_fact f
						on f.patient_num = p.patient_num
				where p.death_date is not null and f.start_date > p.death_date
				group by p.patient_num
			) d on c.patient_num = d.patient_num
end


--******************************************************************************
--******************************************************************************
--*** Precompute some temp tables
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- Create a list of dates since the first case.
--------------------------------------------------------------------------------
create table #date_list (
	d date not null
)
alter table #date_list add primary key (d)
;with n as (
	select 0 n union all select 1 union all select 2 union all select 3 union all select 4 
	union all select 5 union all select 6 union all select 7 union all select 8 union all select 9
)
insert into #date_list
	select d
	from (
		select isnull(cast(dateadd(dd,a.n+10*b.n+100*c.n,p.s) as date),'1/1/2020') d
		from (select min(admission_date) s from #covid_cohort) p
			cross join n a cross join n b cross join n c
	) l
	where d<=GetDate()

--------------------------------------------------------------------------------
-- Create a table with patient demographics.
--------------------------------------------------------------------------------
create table #Demographics_temp (
	patient_num int,
	sex varchar(10),
	age_group varchar(20),
	race varchar(30)
)
-- Get patients' sex
insert into #Demographics_temp (patient_num, sex)
	select patient_num, m.code
	from patient_dimension p
		inner join #code_map m
			on p.sex_cd = m.local_code
				and m.code in ('male','female')
	where patient_num in (select patient_num from #covid_cohort)
-- Get patients' age
insert into #Demographics_temp (patient_num, age_group)
	select patient_num,
		(case
			when age_in_years_num between 0 and 2 then '00to02'
			when age_in_years_num between 3 and 5 then '03to05'
			when age_in_years_num between 6 and 11 then '06to11'
			when age_in_years_num between 12 and 17 then '12to17'
			when age_in_years_num between 18 and 25 then '18to25'
			when age_in_years_num between 26 and 49 then '26to49'
			when age_in_years_num between 50 and 69 then '50to69'
			when age_in_years_num between 70 and 79 then '70to79'
			when age_in_years_num >= 80 then '80plus'
			else 'other' end) age
	from patient_dimension
	where patient_num in (select patient_num from #covid_cohort)
-- Get patients' race(s)
-- (race from patient_dimension)
insert into #Demographics_temp (patient_num, race)
	select p.patient_num, m.code
	from #config x
		cross join patient_dimension p
		inner join #code_map m
			on p.race_cd = m.local_code
	where p.patient_num in (select patient_num from #covid_cohort)
		and x.include_race = 1
		and (
			(x.race_in_fact_table = 0 and m.code in ('american_indian','asian','black','hawaiian_pacific_islander','white'))
			or
			(x.hispanic_in_fact_table = 0 and m.code in ('hispanic_latino'))
		)
-- (race from observation_fact)
insert into #Demographics_temp (patient_num, race)
	select f.patient_num, m.code
	from #config x
		cross join observation_fact f
		inner join #code_map m
			on f.concept_cd = m.local_code
	where f.patient_num in (select patient_num from #covid_cohort)
		and x.include_race = 1
		and (
			(x.race_in_fact_table = 1 and m.code in ('american_indian','asian','black','hawaiian_pacific_islander','white'))
			or
			(x.hispanic_in_fact_table = 1 and m.code in ('hispanic_latino'))
		)
-- Make sure every patient has a sex, age_group, and race
insert into #Demographics_temp (patient_num, sex, age_group, race)
	select patient_num, 'other', null, null
		from #covid_cohort
		where patient_num not in (select patient_num from #Demographics_temp where sex is not null)
	union all
	select patient_num, null, 'other', null
		from #covid_cohort
		where patient_num not in (select patient_num from #Demographics_temp where age_group is not null)
	union all
	select patient_num, null, null, 'other'
		from #covid_cohort
		where patient_num not in (select patient_num from #Demographics_temp where race is not null)


--******************************************************************************
--******************************************************************************
--*** Create data tables
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- Create DailyCounts table.
--------------------------------------------------------------------------------
create table #DailyCounts (
	siteid varchar(50) not null,
	calendar_date date not null,
	cumulative_patients_all int,
	cumulative_patients_severe int,
	cumulative_patients_dead int,
	num_patients_in_hospital_on_this_date int,
	num_patients_in_hospital_and_severe_on_this_date int
)
alter table #DailyCounts add primary key (calendar_date)
insert into #DailyCounts
	select '' siteid, d.*,
		(select count(distinct c.patient_num)
			from #admissions p
				inner join #covid_cohort c
					on p.patient_num=c.patient_num
			where p.admission_date>=c.admission_date
				and p.admission_date<=d.d and p.discharge_date>=d.d
		) num_patients_in_hospital_on_this_date,
		(select count(distinct c.patient_num)
			from #admissions p
				inner join #covid_cohort c
					on p.patient_num=c.patient_num
			where p.admission_date>=c.admission_date
				and p.admission_date<=d.d and p.discharge_date>=d.d
				and c.severe_date<=d.d
		) num_patients_in_hospital_and_severe_on_this_date
	from (
		select d.d,
			sum(case when c.admission_date<=d.d then 1 else 0 end) cumulative_patients_all,
			sum(case when c.severe_date<=d.d then 1 else 0 end) cumulative_patients_severe,
			sum(case when c.death_date<=d.d then 1 else 0 end) cumulative_patients_dead
		from #date_list d
			cross join #covid_cohort c
		group by d.d
	) d
-- Set cumulative_patients_dead = -999 if you do not have accurate death data. 
update #DailyCounts
	set cumulative_patients_dead = -999
	where exists (select * from #config where death_data_accurate = 0)

--------------------------------------------------------------------------------
-- Create ClinicalCourse table.
--------------------------------------------------------------------------------
create table #ClinicalCourse (
	siteid varchar(50) not null,
	days_since_admission int not null,
	num_patients_all_still_in_hospital int,
	num_patients_ever_severe_still_in_hospital int
)
alter table #ClinicalCourse add primary key (days_since_admission)
insert into #ClinicalCourse
	select '' siteid, days_since_admission, 
		count(*),
		sum(severe)
	from (
		select distinct datediff(dd,c.admission_date,d.d) days_since_admission, 
			c.patient_num, severe
		from #date_list d
			inner join #admissions p
				on p.admission_date<=d.d and p.discharge_date>=d.d
			inner join #covid_cohort c
				on p.patient_num=c.patient_num and p.admission_date>=c.admission_date
	) t
	group by days_since_admission

--------------------------------------------------------------------------------
-- Create Demographics table.
--------------------------------------------------------------------------------
create table #Demographics (
	siteid varchar(50) not null,
	sex varchar(10) not null,
	age_group varchar(20) not null,
	race varchar(30) not null,
	num_patients_all int,
	num_patients_ever_severe int
)
alter table #Demographics add primary key (sex, age_group, race)
insert into #Demographics
	select '' siteid, sex, age_group, race, count(*), sum(severe)
	from #covid_cohort c
		inner join (
			select patient_num, sex from #Demographics_temp where sex is not null
			union all
			select patient_num, 'all' from #covid_cohort
		) s on c.patient_num=s.patient_num
		inner join (
			select patient_num, age_group from #Demographics_temp where age_group is not null
			union all
			select patient_num, 'all' from #covid_cohort
		) a on c.patient_num=a.patient_num
		inner join (
			select patient_num, race from #Demographics_temp where race is not null
			union all
			select patient_num, 'all' from #covid_cohort
		) r on c.patient_num=r.patient_num
	group by sex, age_group, race
-- Set counts = -999 if not including race.
update #Demographics
	set num_patients_all = -999, num_patients_ever_severe = -999
	where exists (select * from #config where include_race = 0)

--------------------------------------------------------------------------------
-- Create Labs table.
--------------------------------------------------------------------------------
create table #Labs (
	siteid varchar(50) not null,
	loinc varchar(20) not null,
	days_since_admission int not null,
	units varchar(20),
	num_patients_all int,
	mean_value_all float,
	stdev_value_all float,
	mean_log_value_all float,
	stdev_log_value_all float,
	num_patients_ever_severe int,
	mean_value_ever_severe float,
	stdev_value_ever_severe float,
	mean_log_value_ever_severe float,
	stdev_log_value_ever_severe float
)
alter table #Labs add primary key (loinc, days_since_admission)
insert into #Labs
	select '' siteid, loinc, days_since_admission, lab_units,
		count(*), 
		avg(val), 
		isnull(stdev(val),0),
		avg(logval), 
		isnull(stdev(logval),0),
		sum(severe), 
		(case when sum(severe)=0 then -999 else avg(case when severe=1 then val else null end) end), 
		(case when sum(severe)=0 then -999 else isnull(stdev(case when severe=1 then val else null end),0) end),
		(case when sum(severe)=0 then -999 else avg(case when severe=1 then logval else null end) end), 
		(case when sum(severe)=0 then -999 else isnull(stdev(case when severe=1 then logval else null end),0) end)
	from (
		select loinc, lab_units, patient_num, severe, days_since_admission, 
			avg(val) val, 
			avg(log(val+0.5)) logval -- natural log (ln), not log base 10
		from (
			select l.loinc, l.lab_units, f.patient_num, p.severe,
				datediff(dd,p.admission_date,f.start_date) days_since_admission,
				f.nval_num*l.scale_factor val
			from observation_fact f
				inner join #covid_cohort p 
					on f.patient_num=p.patient_num
				inner join #lab_map l
					on f.concept_cd=l.local_lab_code
			where l.local_lab_code is not null
				and f.nval_num is not null
				and f.nval_num >= 0
				and f.start_date >= p.admission_date
				and l.loinc not in ('2019-8','2703-7')
		) t
		group by loinc, lab_units, patient_num, severe, days_since_admission
	) t
	group by loinc, days_since_admission, lab_units

--------------------------------------------------------------------------------
-- Create Diagnosis table.
-- * Select all ICD9 and ICD10 codes.
-- * Note that just the left 3 characters of the ICD codes should be used.
-- * Customize this query if your ICD codes do not have a prefix.
--------------------------------------------------------------------------------
create table #Diagnoses (
	siteid varchar(50) not null,
	icd_code_3chars varchar(10) not null,
	icd_version int not null,
	num_patients_all_before_admission int,
	num_patients_all_since_admission int,
	num_patients_ever_severe_before_admission int,
	num_patients_ever_severe_since_admission int
)
alter table #Diagnoses add primary key (icd_code_3chars, icd_version)
insert into #Diagnoses
	select '' siteid, icd_code_3chars, icd_version,
		sum(before_admission), 
		sum(since_admission), 
		sum(severe*before_admission), 
		sum(severe*since_admission)
	from (
		-- ICD9
		select distinct p.patient_num, p.severe, 9 icd_version,
			left(substring(f.concept_cd, len(code_prefix_icd9cm)+1, 999), 3) icd_code_3chars,
			(case when f.start_date <= dateadd(dd,-15,p.admission_date) then 1 else 0 end) before_admission,
			(case when f.start_date >= p.admission_date then 1 else 0 end) since_admission
		from #config x
			cross join observation_fact f
			inner join #covid_cohort p 
				on f.patient_num=p.patient_num 
					and f.start_date >= dateadd(dd,-365,p.admission_date)
		where concept_cd like code_prefix_icd9cm+'%' and code_prefix_icd9cm<>''
		-- ICD10
		union all
		select distinct p.patient_num, p.severe, 10 icd_version,
			left(substring(f.concept_cd, len(code_prefix_icd10cm)+1, 999), 3) icd_code_3chars,
			(case when f.start_date <= dateadd(dd,-15,p.admission_date) then 1 else 0 end) before_admission,
			(case when f.start_date >= p.admission_date then 1 else 0 end) since_admission
		from #config x
			cross join observation_fact f
			inner join #covid_cohort p 
				on f.patient_num=p.patient_num 
					and f.start_date >= dateadd(dd,-365,p.admission_date)
		where concept_cd like code_prefix_icd10cm+'%' and code_prefix_icd10cm<>''
	) t
	group by icd_code_3chars, icd_version

--------------------------------------------------------------------------------
-- Create Medications table.
--------------------------------------------------------------------------------
create table #Medications (
	siteid varchar(50) not null,
	med_class varchar(20) not null,
	num_patients_all_before_admission int,
	num_patients_all_since_admission int,
	num_patients_ever_severe_before_admission int,
	num_patients_ever_severe_since_admission int
)
alter table #Medications add primary key (med_class)
insert into #Medications
	select '' siteid, med_class,
		sum(before_admission), 
		sum(since_admission), 
		sum(severe*before_admission), 
		sum(severe*since_admission)
	from (
		select distinct p.patient_num, p.severe, m.med_class,	
			(case when f.start_date <= dateadd(dd,-15,p.admission_date) then 1 else 0 end) before_admission,
			(case when f.start_date >= p.admission_date then 1 else 0 end) since_admission
		from observation_fact f
			inner join #covid_cohort p 
				on f.patient_num=p.patient_num 
					and f.start_date >= dateadd(dd,-365,p.admission_date)
			inner join #med_map m
				on f.concept_cd = m.local_med_code
	) t
	group by med_class


--******************************************************************************
--******************************************************************************
--*** Obfuscate as needed (optional)
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- Blur counts by adding a small random number.
--------------------------------------------------------------------------------
if exists (select * from #config where obfuscation_blur > 0)
begin
	declare @obfuscation_blur int
	select @obfuscation_blur = obfuscation_blur from #config
	update #DailyCounts
		set cumulative_patients_all = cumulative_patients_all + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur,
			cumulative_patients_severe = cumulative_patients_severe + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur,
			cumulative_patients_dead = cumulative_patients_dead + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur,
			num_patients_in_hospital_on_this_date = num_patients_in_hospital_on_this_date + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur,
			num_patients_in_hospital_and_severe_on_this_date = num_patients_in_hospital_and_severe_on_this_date + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur
	update #ClinicalCourse
		set num_patients_all_still_in_hospital = num_patients_all_still_in_hospital + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur,
			num_patients_ever_severe_still_in_hospital = num_patients_ever_severe_still_in_hospital + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur
	update #Demographics
		set num_patients_all = num_patients_all + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur,
			num_patients_ever_severe = num_patients_ever_severe + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur
	update #Labs
		set num_patients_all = num_patients_all + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur,
			num_patients_ever_severe = num_patients_ever_severe + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur
	update #Diagnoses
		set num_patients_all_before_admission = num_patients_all_before_admission + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur,
			num_patients_all_since_admission = num_patients_all_since_admission + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur,
			num_patients_ever_severe_before_admission = num_patients_ever_severe_before_admission + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur,
			num_patients_ever_severe_since_admission = num_patients_ever_severe_since_admission + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur
	update #Medications
		set num_patients_all_before_admission = num_patients_all_before_admission + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur,
			num_patients_all_since_admission = num_patients_all_since_admission + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur,
			num_patients_ever_severe_before_admission = num_patients_ever_severe_before_admission + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur,
			num_patients_ever_severe_since_admission = num_patients_ever_severe_since_admission + FLOOR(ABS(BINARY_CHECKSUM(NEWID())/2147483648.0)*(@obfuscation_blur*2+1)) - @obfuscation_blur
end

--------------------------------------------------------------------------------
-- Mask small counts with "-99".
--------------------------------------------------------------------------------
if exists (select * from #config where obfuscation_small_count_mask > 0)
begin
	declare @obfuscation_small_count_mask int
	select @obfuscation_small_count_mask = obfuscation_small_count_mask from #config
	update #DailyCounts
		set cumulative_patients_all = (case when cumulative_patients_all<@obfuscation_small_count_mask then -99 else cumulative_patients_all end),
			cumulative_patients_severe = (case when cumulative_patients_severe<@obfuscation_small_count_mask then -99 else cumulative_patients_severe end),
			cumulative_patients_dead = (case when cumulative_patients_dead<@obfuscation_small_count_mask then -99 else cumulative_patients_dead end),
			num_patients_in_hospital_on_this_date = (case when num_patients_in_hospital_on_this_date<@obfuscation_small_count_mask then -99 else num_patients_in_hospital_on_this_date end),
			num_patients_in_hospital_and_severe_on_this_date = (case when num_patients_in_hospital_and_severe_on_this_date<@obfuscation_small_count_mask then -99 else num_patients_in_hospital_and_severe_on_this_date end)
	update #ClinicalCourse
		set num_patients_all_still_in_hospital = (case when num_patients_all_still_in_hospital<@obfuscation_small_count_mask then -99 else num_patients_all_still_in_hospital end),
			num_patients_ever_severe_still_in_hospital = (case when num_patients_ever_severe_still_in_hospital<@obfuscation_small_count_mask then -99 else num_patients_ever_severe_still_in_hospital end)
	update #Demographics
		set num_patients_all = (case when num_patients_all<@obfuscation_small_count_mask then -99 else num_patients_all end),
			num_patients_ever_severe = (case when num_patients_ever_severe<@obfuscation_small_count_mask then -99 else num_patients_ever_severe end)
	update #Labs
		set num_patients_all=-99, mean_value_all=-99, stdev_value_all=-99, mean_log_value_all=-99, stdev_log_value_all=-99
		where num_patients_all<@obfuscation_small_count_mask
	update #Labs
		set num_patients_ever_severe=-99, mean_value_ever_severe=-99, stdev_value_ever_severe=-99, mean_log_value_ever_severe=-99, stdev_log_value_ever_severe=-99
		where num_patients_ever_severe<@obfuscation_small_count_mask
	update #Diagnoses
		set num_patients_all_before_admission = (case when num_patients_all_before_admission<@obfuscation_small_count_mask then -99 else num_patients_all_before_admission end),
			num_patients_all_since_admission = (case when num_patients_all_since_admission<@obfuscation_small_count_mask then -99 else num_patients_all_since_admission end),
			num_patients_ever_severe_before_admission = (case when num_patients_ever_severe_before_admission<@obfuscation_small_count_mask then -99 else num_patients_ever_severe_before_admission end),
			num_patients_ever_severe_since_admission = (case when num_patients_ever_severe_since_admission<@obfuscation_small_count_mask then -99 else num_patients_ever_severe_since_admission end)
	update #Medications
		set num_patients_all_before_admission = (case when num_patients_all_before_admission<@obfuscation_small_count_mask then -99 else num_patients_all_before_admission end),
			num_patients_all_since_admission = (case when num_patients_all_since_admission<@obfuscation_small_count_mask then -99 else num_patients_all_since_admission end),
			num_patients_ever_severe_before_admission = (case when num_patients_ever_severe_before_admission<@obfuscation_small_count_mask then -99 else num_patients_ever_severe_before_admission end),
			num_patients_ever_severe_since_admission = (case when num_patients_ever_severe_since_admission<@obfuscation_small_count_mask then -99 else num_patients_ever_severe_since_admission end)
end

--------------------------------------------------------------------------------
-- To protect obfuscated demographics breakdowns, keep individual sex, age,
--   and race breakdowns, set combinations and the total count to -999.
--------------------------------------------------------------------------------
if exists (select * from #config where obfuscation_demographics = 1)
begin
	update #Demographics
		set num_patients_all = -999, num_patients_ever_severe = -999
		where (case sex when 'all' then 1 else 0 end)
			+(case race when 'all' then 1 else 0 end)
			+(case age_group when 'all' then 1 else 0 end)<>2
end

--------------------------------------------------------------------------------
-- Delete small counts.
--------------------------------------------------------------------------------
if exists (select * from #config where obfuscation_small_count_delete = 1)
begin
	declare @obfuscation_small_count_delete int
	select @obfuscation_small_count_delete = obfuscation_small_count_mask from #config
	delete from #DailyCounts where cumulative_patients_all<@obfuscation_small_count_delete
	delete from #ClinicalCourse where num_patients_all_still_in_hospital<@obfuscation_small_count_delete
	delete from #Labs where num_patients_all<@obfuscation_small_count_delete
	delete from #Diagnoses where num_patients_all_before_admission<@obfuscation_small_count_delete and num_patients_all_since_admission<@obfuscation_small_count_delete
	delete from #Medications where num_patients_all_before_admission<@obfuscation_small_count_delete and num_patients_all_since_admission<@obfuscation_small_count_delete
end

--******************************************************************************
--******************************************************************************
--*** Finish up
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- Set the siteid to a unique value for your institution.
-- * Make sure you are not using another institution's siteid.
-- * The siteid must be no more than 20 letters or numbers.
-- * It must start with a letter.
-- * It cannot have any blank spaces or special characters.
--------------------------------------------------------------------------------
update #DailyCounts set siteid = (select siteid from #config)
update #ClinicalCourse set siteid = (select siteid from #config)
update #Demographics set siteid = (select siteid from #config)
update #Labs set siteid = (select siteid from #config)
update #Diagnoses set siteid = (select siteid from #config)
update #Medications set siteid = (select siteid from #config)

--------------------------------------------------------------------------------
-- OPTION #1: View the data as tables.
-- * Make sure everything looks reasonable.
-- * Copy into Excel, convert dates into YYYY-MM-DD format, save in csv format.
--------------------------------------------------------------------------------
if exists (select * from #config where output_as_columns = 1)
begin
	select * from #DailyCounts order by calendar_date
	select * from #ClinicalCourse order by days_since_admission
	select * from #Demographics order by sex, age_group, race
	select * from #Labs order by loinc, days_since_admission
	select * from #Diagnoses order by num_patients_all_since_admission desc, num_patients_all_before_admission desc
	select * from #Medications order by num_patients_all_since_admission desc, num_patients_all_before_admission desc
end

--------------------------------------------------------------------------------
-- OPTION #2: View the data as csv strings.
-- * Copy and paste to a text file, save it FileName.csv.
-- * Make sure it is not saved as FileName.csv.txt.
--------------------------------------------------------------------------------
if exists (select * from #config where output_as_csv = 1)
begin

	-- DailyCounts
	select s DailyCountsCSV
		from (
			select 0 i, 'siteid,calendar_date,cumulative_patients_all,cumulative_patients_severe,cumulative_patients_dead,'
				+'num_patients_in_hospital_on_this_date,num_patients_in_hospital_and_severe_on_this_date' s
			union all 
			select row_number() over (order by calendar_date) i,
				siteid
				+','+convert(varchar(50),calendar_date,23) --YYYY-MM-DD
				+','+cast(cumulative_patients_all as varchar(50))
				+','+cast(cumulative_patients_severe as varchar(50))
				+','+cast(cumulative_patients_dead as varchar(50))
				+','+cast(num_patients_in_hospital_on_this_date as varchar(50))
				+','+cast(num_patients_in_hospital_and_severe_on_this_date as varchar(50))
			from #DailyCounts
			union all select 9999999, '' --Add a blank row to make sure the last line in the file with data ends with a line feed.
		) t
		order by i

	-- ClinicalCourse
	select s ClinicalCourseCSV
		from (
			select 0 i, 'siteid,days_since_admission,num_patients_all_still_in_hospital,num_patients_ever_severe_still_in_hospital' s
			union all 
			select row_number() over (order by days_since_admission) i,
				siteid
				+','+cast(days_since_admission as varchar(50))
				+','+cast(num_patients_all_still_in_hospital as varchar(50))
				+','+cast(num_patients_ever_severe_still_in_hospital as varchar(50))
			from #ClinicalCourse
			union all select 9999999, '' --Add a blank row to make sure the last line in the file with data ends with a line feed.
		) t
		order by i

	-- Demographics
	select s DemographicsCSV
		from (
			select 0 i, 'siteid,sex,age_group,race,num_patients_all,num_patients_ever_severe' s
			union all 
			select row_number() over (order by sex, age_group, race) i,
				siteid
				+','+cast(sex as varchar(50))
				+','+cast(age_group as varchar(50))
				+','+cast(race as varchar(50))
				+','+cast(num_patients_all as varchar(50))
				+','+cast(num_patients_ever_severe as varchar(50))
			from #Demographics
			union all select 9999999, '' --Add a blank row to make sure the last line in the file with data ends with a line feed.
		) t
		order by i

	-- Labs
	select s LabsCSV
		from (
			select 0 i, 'siteid,loinc,days_since_admission,units,'
				+'num_patients_all,mean_value_all,stdev_value_all,mean_log_value_all,stdev_log_value_all,'
				+'num_patients_ever_severe,mean_value_ever_severe,stdev_value_ever_severe,mean_log_value_ever_severe,stdev_log_value_ever_severe' s
			union all 
			select row_number() over (order by loinc, days_since_admission) i,
				siteid
				+','+cast(loinc as varchar(50))
				+','+cast(days_since_admission as varchar(50))
				+','+cast(units as varchar(50))
				+','+cast(num_patients_all as varchar(50))
				+','+cast(mean_value_all as varchar(50))
				+','+cast(stdev_value_all as varchar(50))
				+','+cast(mean_log_value_all as varchar(50))
				+','+cast(stdev_log_value_all as varchar(50))
				+','+cast(num_patients_ever_severe as varchar(50))
				+','+cast(mean_value_ever_severe as varchar(50))
				+','+cast(stdev_value_ever_severe as varchar(50))
				+','+cast(mean_log_value_ever_severe as varchar(50))
				+','+cast(stdev_log_value_ever_severe as varchar(50))
			from #Labs
			union all select 9999999, '' --Add a blank row to make sure the last line in the file with data ends with a line feed.
		) t
		order by i

	-- Diagnoses
	select s DiagnosesCSV
		from (
			select 0 i, 'siteid,icd_code_3chars,icd_version,'
				+'num_patients_all_before_admission,num_patients_all_since_admission,'
				+'num_patients_ever_severe_before_admission,num_patients_ever_severe_since_admission' s
			union all 
			select row_number() over (order by num_patients_all_since_admission desc, num_patients_all_before_admission desc) i,
				siteid
				+','+cast(icd_code_3chars as varchar(50))
				+','+cast(icd_version as varchar(50))
				+','+cast(num_patients_all_before_admission as varchar(50))
				+','+cast(num_patients_all_since_admission as varchar(50))
				+','+cast(num_patients_ever_severe_before_admission as varchar(50))
				+','+cast(num_patients_ever_severe_since_admission as varchar(50))
			from #Diagnoses
			union all select 9999999, '' --Add a blank row to make sure the last line in the file with data ends with a line feed.
		) t
		order by i

	-- Medications
	select s MedicationsCSV
		from (
			select 0 i, 'siteid,med_class,'
				+'num_patients_all_before_admission,num_patients_all_since_admission,'
				+'num_patients_ever_severe_before_admission,num_patients_ever_severe_since_admission' s
			union all 
			select row_number() over (order by num_patients_all_since_admission desc, num_patients_all_before_admission desc) i,
				siteid
				+','+cast(med_class as varchar(50))
				+','+cast(num_patients_all_before_admission as varchar(50))
				+','+cast(num_patients_all_since_admission as varchar(50))
				+','+cast(num_patients_ever_severe_before_admission as varchar(50))
				+','+cast(num_patients_ever_severe_since_admission as varchar(50))
			from #Medications
			union all select 9999999, '' --Add a blank row to make sure the last line in the file with data ends with a line feed.
		) t
		order by i

end


