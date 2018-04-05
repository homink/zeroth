#!/bin/bash

# You will install mecab-ko and mecab-ko-dic from https://bitbucket.org/eunjeon/mecab-ko-dic
# if not installed on your system
# Morfessor installation info is https://github.com/aalto-speech/morfessor

. ./cmd.sh
. ./path.sh

srcdir=dict
scriptdir=buildLM/_scripts_

rm -rf $srcdir
mkdir -p $srcdir
sejong=/home/kwon/copora/sejong.txt
#cat $sejong | tr " " "\n" | tr "\n\n" "\n" | uniq > $srcdir/uniqWordList

echo 'Text normalization starts ---------------------------------------------------'
/home/kwon/anaconda3/bin/python3 $scriptdir/normStep1.py $sejong | \
    /home/kwon/anaconda3/bin/python3 $scriptdir/normStep2.py | \
    /home/kwon/anaconda3/bin/python3 $scriptdir/normStep_tmp.py | \
    /home/kwon/anaconda3/bin/python3 $scriptdir/normStep4.py | \
    /home/kwon/anaconda3/bin/python3 $scriptdir/strip.py > $srcdir/normedCorpus.0 || exit 1;

echo 'Finding Uniq. words for morpheme analysis --------------------------------------'
cat $srcdir/normedCorpus.0 | \
    tr -s [:space:] '\n' | sort | uniq -c | \
    sort -k1 -n -r > $srcdir/uniqWords.0

echo "Accumulate statistics into: uniqWordList ------------------------------------------"
if [ ! -f $srcdir/uniqWordList ]; then
    cat $srcdir/uniqWords.0 | \
        /home/kwon/anaconda3/bin/python3 $scriptdir/sumStatUniqWords.py > $srcdir/uniqWordList
    stat=$(awk 'BEGIN{sum=0;cnt=0}{cnt+=1;if($2 == 1){sum+=1}}END{print sum"/"cnt}' $srcdir/uniqWordList)
    echo "  total uniq. word count: $(echo $stat | awk -F'/' '{print $2}')"
    percentage=$(echo "print('portion of freq.== 1 word: {:.2f} %'.format($stat*100))" | /home/kwon/anaconda3/bin/python3)
    echo "  $percentage"
fi

echo "Pruning uniqWordList for Morfessor training -----------------------------------------"
coverage=0.98
srcFile=$srcdir/uniqWordList
inFile=$srcdir/uniqWordList.hangul
inFile2=$srcdir/uniqWordList.nonhangul
outFile=$srcdir/uniqWordList.hangul.pruned
if [ ! -f $inFile ]; then
    grep -E '[가-힣]+ [0-9]+' $srcFile |\
                awk -v file=$inFile '{if(length($1)<=10 || $2>5){print $0}else{print $0 > file".remained"}}' > $inFile  ##  
        grep -v -E '[가-힣]+ [0-9]+' $srcFile > $inFile2

        totalCnt=$(awk 'BEGIN{sum=0}{sum+=$2}END{print sum}' $inFile)
    echo '  pruned coverge:' $coverage
    echo '  total acc. count:' $totalCnt
    awk -v totalCnt="$totalCnt" -v coverage="$coverage" -v file=$outFile \
        'BEGIN{sum=0}{sum+=$2; if(sum/totalCnt <= coverage){print $1}else{print $1 > file".remained"}}' $inFile > $outFile
        echo "  final uniq. word for training: $(wc -l <$outFile)"
fi

echo 'Morfessor model training  -----------------------------------------------------------'
if [ ! -f $srcdir/morfessor.model.pickled ]; then
    morfessor --traindata-list \
        -t $outFile \
        -S $srcdir/morfessor.model.txt \
        -s $srcdir/morfessor.model.pickled \
        -x $srcdir/morfessor.lexicon \
        --randsplit 0.5 --skips \
        --progressbar \
        --nosplit-re '[0-9\[\]\(\){}a-zA-Z&.,\-]+'

fi

segModel=$srcdir/morfessor.model.pickled
segModelTxt=$srcdir/morfessor.model.txt
segModelLexicon=$srcdir/morfessor.lexicon

:<<"SKIP1"
if [ -f buildLM/_corpus_task_/morfessor.model.pickled ] && 
	[ buildLM/_corpus_task_/morfessor.model.pickled -nt $srcdir/morfessor.model.pickled ]; then
	segModel=buildLM/_corpus_task_/morfessor.model.pickled
	segModelTxt=buildLM/_corpus_task_/morfessor.model.txt
	segModelLexicon=buildLM/_corpus_task_/morfessor.lexicon
	echo "  found more recently trained segment model: "
	echo "  1.  $segModel"
	echo "  2.  $segModelTxt"
	echo "  3.  $segModelLexicon"
	echo "  use this one"
fi
SKIP1

echo 'Morpheme segmentation --------------------------------------------------------------'
morfessor -l $segModel \
    --output-format '{analysis} ' -T $srcdir/normedCorpus.0 \
    -o $srcdir/normedCorpus.seg.0 --output-newlines \
    --nosplit-re "'[0-9\[\]\(\){}a-zA-Z&.,\-]+'"

echo 'Extract uniq Morphemes ----------------------------------------------------------'
# nonHangulList from general domain (freq. > 10)  + morphemes from Morfessor
if [ ! -f $srcdir/morphemes ]; then

	cat $srcdir/uniqWordList.nonhangul | grep -E "^[A-Z]+ " > $srcdir/uniqWordList.nonhangul.alphabet
	cat $srcdir/uniqWordList.nonhangul | grep -v -E "^[A-Z]+ " | awk '{print $1}' > $srcdir/morphemes.etc

	coverage=0.98
	totalCnt=$(awk 'BEGIN{sum=0}{sum+=$2}END{print sum}' $srcdir/uniqWordList.nonhangul.alphabet)
    awk -v totalCnt="$totalCnt" -v coverage="$coverage" \
        'BEGIN{sum=0}{sum+=$2; if(sum/totalCnt <= coverage){print $1}}' $srcdir/uniqWordList.nonhangul.alphabet \
		> $srcdir/morphemes.alphabet


	cat $segModelLexicon | awk '{print $2}' > $srcdir/morphemes.hangul
	cat $srcdir/morphemes.hangul $srcdir/morphemes.alphabet $srcdir/morphemes.etc |\
		sort | uniq > $srcdir/morphemes
	
	echo '  morphemes hangul: '$(wc -l <$srcdir/morphemes.hangul)
	echo '  morphemes alphabet: '$(wc -l <$srcdir/morphemes.alphabet)
	echo '  morphemes etc: '$(wc -l <$srcdir/morphemes.etc)
	echo '  total morphemes: '$(wc -l <$srcdir/morphemes) 
	echo '  check morphemes longer than 10 characters'
	awk 'BEGIN{sum=0;total=0}{if(length($1)>10){print $0;sum+=1}total+=1}END{print(sum" "total)}' \
		$srcdir/morphemes
fi

echo "Starts to build lexicon ----------------------------------------------------------"
if [ ! -f $srcdir/lexicon ]; then
    $scriptdir/buildLexicon.sh $srcdir $segModelTxt
fi
