#!/bin/sh

#set -x

#========================
#MAGIC CONSTANTS
#========================

MAX_TILE_X=50
MAX_TILE_Y=50

CURL_HTTP_ERROR=22
CURL_TIMEOUT=28

MIN_FILE_SIZE_BYTES=1024

#========================
#HELPER FUNCTIONS
#========================


webGet()
{
	if [ $# -ne 2 ]
	then
		echo "Usage: $0 url output_file"
		return 1
	fi

	local URL=$1
	local OUTPUT_FILE=$2

	if [ -f "$OUTPUT_FILE" ]
	then
		return 0
	fi

	echo -n "Getting $1 ... "

	curl \
		--silent \
		--fail \
		--retry 2 \
		--insecure \
		--connect-timeout 3 \
		--retry-delay 2 \
		--max-time 60 \
		--output "$OUTPUT_FILE" \
		"$URL"

	local EXIT_CODE=$?

	if [ "$EXIT_CODE" -eq "$CURL_TIMEOUT" ]
	then
		echo "TIMEOUT"
		return 1
	fi
	if [ "$EXIT_CODE" -eq "$CURL_HTTP_ERROR" ]
	then
		rm -f "$OUTPUT_FILE"
		echo "HTTP ERROR"
		return 1
	fi
	if [ ! -e "$OUTPUT_FILE" ]
	then
		echo "NO OUTPUT"
		return 1
	fi

	if [ `stat --format=%s "$OUTPUT_FILE"` -lt "$MIN_FILE_SIZE_BYTES" ]
	then
		rm -f "$OUTPUT_FILE"
		echo "FILE TOO SMALL"
		return 1
	fi

	echo "OK"
	return 0
}

#Utility functions
max()
{
	local MAX=$1
	shift

	for CANDIDATE in $@
	do
		if [ "$CANDIDATE" -gt "$MAX" ]
		then
			MAX=$CANDIDATE
		fi
	done

	echo $MAX
}

min()
{
	local MIN=$1
	shift

	for CANDIDATE in $@
	do
		if [ "$CANDIDATE" -lt "$MIN" ]
		then
			MIN=$CANDIDATE
		fi
	done

	echo $MIN
}

roundDiv()
{
	local VAL=$1
	local DIVISOR=$2

	local RESULT=`echo "$VAL" / "$DIVISOR" | bc`
	local REST=`echo "$VAL" % "$DIVISOR" | bc`
	if [ "$REST" -eq 0 ]
	then
		echo $RESULT
	else
		echo "$RESULT" + 1 | bc
	fi
}

dullValidate()
{
	return 0
}

tiles()
{
	if [ $# -ne 7 ]
	then
		echo "Usage: $0 urlGenerator fileGenerator fileValidator pageId zoom outputDir"
		return 1
	fi

	local URL_GENERATOR=$1
	local FILE_GENERATOR=$2
	local TILE_VALIDATOR=$3
	local PAGE_ID=$4
	local TILE_Z=$5
	local TILE_SIZE=$6
	local OUTPUT_DIR=$7
	local OUTPUT_FILE="$OUTPUT_DIR/`basename $PAGE_ID`.bmp"
	local TMP_DIR="$OUTPUT_DIR/`basename $PAGE_ID`.tmp"

	local LAST_TILE_WIDTH=$TILE_SIZE
	local LAST_TILE_HEIGHT=$TILE_HEIGHT

	mkdir -p "$TMP_DIR"
	for TILE_X in `seq 0 $MAX_TILE_X`
	do
		local TILE_Y=0
		local TILE_FILE="$TMP_DIR/`$FILE_GENERATOR $TILE_X $TILE_Y`.jpg"
		webGet `$URL_GENERATOR $PAGE_ID $TILE_X $TILE_Y $TILE_Z` "$TILE_FILE" && $TILE_VALIDATOR "$TILE_FILE"
		if [ $? -ne 0 ]
		then			
			rm -f "$TILE_FILE"
			local MAX_TILE_X=`expr $TILE_X - 1`
			local LAST_TILE_FILE="$TMP_DIR/`$FILE_GENERATOR $MAX_TILE_X 0`.jpg"
			local LAST_TILE_WIDTH=`identify -format '%w' "$LAST_TILE_FILE"`
			break
		fi

		for TILE_Y in `seq 0 $MAX_TILE_Y`
		do
			local TILE_FILE="$TMP_DIR/`$FILE_GENERATOR $TILE_X $TILE_Y`.jpg"
			webGet `$URL_GENERATOR $PAGE_ID $TILE_X $TILE_Y $TILE_Z` "$TILE_FILE" && $TILE_VALIDATOR "$TILE_FILE"

			if [ $? -ne 0 ]
			then
				rm -f "$TILE_FILE"
				local MAX_TILE_Y=`expr $TILE_Y - 1`
				local LAST_TILE_FILE="$TMP_DIR/`$FILE_GENERATOR 0 $MAX_TILE_Y`.jpg"
				local LAST_TILE_HEIGHT=`identify -format '%h' "$LAST_TILE_FILE"`
				break
			fi
		done;
	done;

	if [ \
		"$MAX_TILE_X" -gt "0" -a \
		"$MAX_TILE_Y" -gt "0" \
	]
	then
		for row in `seq 0 $MAX_TILE_Y`
		do
			#fixing size of last tile in each row
			local LAST_TILE_FILE="$TMP_DIR/`$FILE_GENERATOR $MAX_TILE_X $row`.jpg"
			local LAST_TILE_FIXED_FILE="$TMP_DIR/`$FILE_GENERATOR $MAX_TILE_X $row`.bmp"
			local OLD_WIDTH=`identify -format "%w" $LAST_TILE_FILE`
			local OLD_HEIGHT=`identify -format "%h" $LAST_TILE_FILE`
			if [ "$row" != "$MAX_TILE_Y" ]
			then
				#resizing last column of tiles to have TILE_SIZE height
				local NEW_WIDTH=`expr "$OLD_WIDTH * $TILE_SIZE / $OLD_HEIGHT" | bc`
				local NEW_HEIGHT=$TILE_SIZE
			else
				#resizing last tile to match the previous in the grid
				local NEW_HEIGHT=$LAST_TILE_HEIGHT
				local NEW_WIDTH=`echo "$OLD_WIDTH * $LAST_TILE_HEIGHT / $OLD_HEIGHT" | bc`
			fi
			convert "$LAST_TILE_FILE" -resize "${NEW_WIDTH}x${NEW_HEIGHT}!" "$LAST_TILE_FIXED_FILE"
			rm -f "$LAST_TILE_FILE"
		done

		montage \
			$TMP_DIR/* \
			-mode Concatenate \
			-geometry "${TILE_SIZE}x${TILE_SIZE}>" \
			-tile `expr $MAX_TILE_X + 1`x`expr $MAX_TILE_Y + 1` \
			$OUTPUT_FILE
		if [ ! "$NO_TRIM" ]
		then
			convert $OUTPUT_FILE -trim $OUTPUT_FILE
		fi
	fi
	
	rm -rf "$TMP_DIR"
}

# removes wrong symbols from filename, replacing them by underscores
makeOutputDir()
{
	local OUTPUT_DIR=$1
	echo "$OUTPUT_DIR" | sed -e 's/[:\/\\\?\*"]/_/g'
}

#========================
#LIBRARY DEPENDENT FUNCTIONS
#========================

#========================
#Tiled page downloaders
#========================
generalTilesFile()
{
	if [ $# -ne 2 ]
	then
		echo "Usage: $0 x y"
		return 1
	fi

	local TILE_X=$1
	local TILE_Y=$2

	printf "%04d_%04d" "$TILE_Y" "$TILE_X"
}

princetonTilesUrl()
{
	if [ $# -ne 4 ]
	then
		echo "Usage: $0 ark_id x y z"
		return 1
	fi

	local BOOK_ID=$1
	local TILE_X=$2
	local TILE_Y=$3
	local TILE_Z=$4
	local TILE_SIZE=1024

	local LEFT=`expr $TILE_X '*' $TILE_SIZE`
	local TOP=`expr $TILE_Y '*' $TILE_SIZE`

	echo "http://libimages.princeton.edu/loris/$BOOK_ID/$LEFT,$TOP,1024,1024/1024,/0/native.jpg"
}

princetonTiles()
{
	if [ $# -ne 1 ]
	then
		echo "Usage: $0 item_id"
		return 1
	fi

	#overriding global constant
	MIN_FILE_SIZE_BYTES=5120

	local BOOK_ID=$1
	local ZOOM=6
	local TILE_SIZE=1024
	local OUTPUT_DIR=.


	tiles princetonTilesUrl generalTilesFile dullValidate $BOOK_ID $ZOOM $TILE_SIZE $OUTPUT_DIR
}

dusseldorfTileFile()
{
	if [ $# -ne 2 ]
	then
		echo "Usage: $0 x y"
		return 1
	fi

	local TILE_X=$1
	local TILE_Y=$2
	local BASE_TILE_Y=50
	#dusseldorf tiles are numbered from bottom to top
	local REAL_TILE_Y=`expr $BASE_TILE_Y - $TILE_Y`

	generalTilesFile "$TILE_X" "$REAL_TILE_Y"
}

dusseldorfTilesUrl()
{
	if [ $# -ne 4 ]
	then
		echo "Usage: $0 image_id x y z"
		return 1
	fi

	local IMAGE_ID=$1
	local TILE_X=$2
	local TILE_Y=$3
	local TILE_Z=$4

	#some unknown number with unspecified purpose
	local UNKNOWN_NUMBER=5089
	local VERSION=1.0.0

	echo "http://digital.ub.uni-duesseldorf.de/image/tile/wc/nop/$UNKNOWN_NUMBER/$VERSION/$IMAGE_ID/$TILE_Z/$TILE_X/$TILE_Y.jpg"
}

dusseldorfTiles()
{
	if [ $# -ne 1 ]
	then
		echo "Usage: $0 image_id"
		return 1
	fi
	local BOOK_ID=$1
	local ZOOM=6
	local TILE_SIZE=512
	local OUTPUT_DIR=.

	#overriding global constant
	MIN_FILE_SIZE_BYTES=5120

	tiles dusseldorfTilesUrl dusseldorfTileFile dullValidate $BOOK_ID $ZOOM $TILE_SIZE $OUTPUT_DIR
}

uniHalleTileFile()
{
	if [ $# -ne 2 ]
	then
		echo "Usage: $0 x y"
		return 1
	fi

	local TILE_X=$1
	local TILE_Y=$2
	#dusseldorf tiles are numbered from bottom to top
	local REAL_TILE_Y=`expr $MAX_TILE - $TILE_Y`

	generalTilesFile "$TILE_X" "$REAL_TILE_Y"
}

#quite similar to dusseldorf, with different magic numbers
uniHalleTilesUrl()
{
	if [ $# -ne 4 ]
	then
		echo "Usage: $0 image_id x y z"
		return 1
	fi

	local IMAGE_ID=$1
	local TILE_X=$2
	local TILE_Y=$3
	local TILE_Z=$4

	#some unknown number with unspecified purpose
	local UNKNOWN_NUMBER=1157
	local VERSION=1.0.0

	echo "http://digitale.bibliothek.uni-halle.de/image/tile/wc/nop/$UNKNOWN_NUMBER/$VERSION/$IMAGE_ID/$TILE_Z/$TILE_X/$TILE_Y.jpg"
}

uniHalleTiles()
{
	if [ $# -ne 1 ]
	then
		echo "Usage: $0 image_id"
		return 1
	fi
	local BOOK_ID=$1
	local ZOOM=3
	local TILE_SIZE=512
	local OUTPUT_DIR=.

	#overriding global constant
	MIN_FILE_SIZE_BYTES=5120

	tiles uniHalleTilesUrl uniHalleTileFile dullValidate $BOOK_ID $ZOOM $TILE_SIZE $OUTPUT_DIR
}

kunstkameraTilesUrl()
{
	if [ $# -ne 4 ]
	then
		echo "Usage: $0 image_id x y z"
		return 1
	fi

	local IMAGE_ID=$1
	local TILE_X=$2
	local TILE_Y=$3
	local TILE_SIZE=512

	local TILE_LEFT=`expr $TILE_X '*' $TILE_SIZE`
	local TILE_TOP=`expr $TILE_Y '*' $TILE_SIZE`

	echo "http://kunstkamera.ru/kunst-catalogue/spf/${IMAGE_ID}.jpg?w=${TILE_SIZE}&h=${TILE_SIZE}&cl=${TILE_LEFT}&ct=${TILE_TOP}&cw=${TILE_SIZE}&ch=${TILE_SIZE}"
}

kunstkameraTiles()
{
	if [ $# -ne 1 ]
	then
		echo "Usage: $0 image_id"
		return 1
	fi
	local BOOK_ID=$1
	local ZOOM=4
	local TILE_SIZE=512
	local OUTPUT_DIR=`makeOutputDir kunstkamera`

	#overriding global constant
	MIN_FILE_SIZE_BYTES=1

	tiles kunstkameraTilesUrl generalTilesFile dullValidate $BOOK_ID $ZOOM $TILE_SIZE $OUTPUT_DIR
}

ugentTilesUrl()
{
	if [ $# -ne 4 ]
	then
		echo "Usage $0 image_id x y z"
		return 1
	fi
	#expecting BOOK_ID in form of B3D7E912-00D1-11E6-BCF2-CC0ED53445F2:DS.42
	local BOOK_ID=$1
	local TILE_X=$2
	local TILE_Y=$3
	local ZOOM=$4
	local TILE_SIZE=1024
	
	local LEFT=`expr $TILE_X '*' $TILE_SIZE`
	local TOP=`expr $TILE_Y '*' $TILE_SIZE`

	#FIXME: this number should be manually adjusted to get correct results
	echo "http://adore.ugent.be/IIIF/images/archive.ugent.be:$BOOK_ID/$LEFT,$TOP,$TILE_SIZE,$TILE_SIZE/$TILE_SIZE,/0/default.jpg"
}

ugentTilesValidate()
{
	local TILE_FILE=$1
	local HEIGHT=`identify -format "%h" $TILE_FILE`
	#when out of bound, ugent will respond with some rainbow image with height=4000
	test $HEIGHT -ne 4000
	return $?
}

ugentTiles()
{
	if [ $# -ne 1 ]
	then
		echo "Usage: $0 image_id"
		return 1
	fi
	local BOOK_ID=$1
	local ZOOM=5
	local TILE_SIZE=1024
	local OUTPUT_DIR=`makeOutputDir ugent`

	#overriding global constant with some magic value (with 276 kilobytes)
	MIN_FILE_SIZE_BYTES=282624

	tiles ugentTilesUrl generalTilesFile ugentTilesValidate $BOOK_ID $ZOOM $TILE_SIZE $OUTPUT_DIR
}

uflEduTilesUrl()
{
	if [ $# -ne 4 ]
	then
		echo "Usage $0 image_id x y z"
		return 1
	fi
	#expecting BOOK_ID in form of
	#AA/00/03/94/08/00001/00522
	#(not including jp2 extension)
	local BOOK_ID=$1
	local TILE_X=$2
	local TILE_Y=$3
	local ZOOM=$4

	echo "http://ufdc.ufl.edu/iipimage/iipsrv.fcgi?DeepZoom=//flvc.fs.osg.ufl.edu/flvc-ufdc/resources/${BOOK_ID}.jp2_files/${ZOOM}/${TILE_X}_${TILE_Y}.jpg"
}

uflEduTiles()
{
	if [ $# -ne 1 ]
	then
		echo "Usage: $0 image_id"
		return 1
	fi
	local BOOK_ID="$1"
	local ZOOM=-1
	for TEST_ZOOM in `seq 13 -1 11`
	do
		if curl --fail --silent --head "`uflEduTilesUrl $BOOK_ID 0 0 $TEST_ZOOM`"
		then
			ZOOM=$TEST_ZOOM
			break
		fi
	done
	if [ $ZOOM -eq "-1" ]
	then
		echo "Unable to get max zoom"
		return 1
	fi
	local TILE_SIZE=256
	local OUTPUT_DIR=`makeOutputDir ufl.edu`

	local DZI_URL="http://ufdc.ufl.edu/iipimage/iipsrv.fcgi?DeepZoom=//flvc.fs.osg.ufl.edu/flvc-ufdc/resources/${BOOK_ID}.jp2.dzi"
	local IMG_WIDTH=`curl --silent "$DZI_URL" | sed 's/xmlns=".*"//g' | xmllint --xpath "string(/Image/Size/@Width)" -`
	local IMG_HEIGHT=`curl --silent "$DZI_URL" | sed 's/xmlns=".*"//g' | xmllint --xpath "string(/Image/Size/@Height)" -`

	#overriding global constants
	MIN_FILE_SIZE_BYTES=1
	MAX_TILE_X=`echo \`roundDiv ${IMG_WIDTH} 256\` - 1 | bc`
	MAX_TILE_Y=`echo \`roundDiv ${IMG_HEIGHT} 256\` - 1 | bc`

	tiles uflEduTilesUrl generalTilesFile dullValidate $BOOK_ID $ZOOM $TILE_SIZE $OUTPUT_DIR
}

uflEdu()
{
	if [ $# -ne 2 ]
	then
		echo "Usage $0 ark_id page_count"
		return 1
	fi

	#expecting BOOK_ID in form of
	#AA/00/03/94/08/00001
	local BOOK_ID=$1
	local OUTPUT_DIR=`makeOutputDir "gallica.$BOOK_ID"`
	local PAGE_COUNT=$2
	mkdir -p "$OUTPUT_DIR"
	for PAGE in `seq 1 $PAGE_COUNT`
	do
		local PAGE_ID="${BOOK_ID}/`printf %05d $PAGE`"
		local DOWNLOADED_FILE="${PAGE_ID}.bmp"
		local OUTPUT_FILE=`printf $OUTPUT_DIR/%04d.bmp $PAGE`
		if [ ! -f "$OUTPUT_FILE" ]
		then
			uflEduTiles "$PAGE_ID"
			mv "$DOWNLOADED_FILE" "$OUTPUT_FILE"
		fi
	done
}

historyOrgTilesUrl()
{
	if [ $# -ne 4 ]
	then
		echo "Usage $0 image_id x y z"
		return 1
	fi
	local BOOK_ID=$1
	local TILE_X=$2
	local TILE_Y=$3
	local ZOOM=$4
	
	for TILE_GROUP in `seq 0 2`
	do
		local URL="http://www.history.org/history/museums/clothingexhibit/images/accessories/${BOOK_ID}/TileGroup${TILE_GROUP}/${ZOOM}-${TILE_X}-${TILE_Y}.jpg"
		curl --silent -I "$URL" | grep "HTTP/1.1 200 OK" > /dev/null
		if [ "$?" -eq 0 ]
		then
			echo "$URL"
			return
		fi
	done
}

historyOrgTiles()
{
	if [ $# -ne 1 ]
	then
		echo "Usage: $0 image_id"
		return 1
	fi
	local BOOK_ID="$1"
	local ZOOM=4
	local TILE_SIZE=256
	local OUTPUT_DIR=`makeOutputDir history.org`

	#overriding global constants
	MIN_FILE_SIZE_BYTES=1

	tiles historyOrgTilesUrl generalTilesFile dullValidate $BOOK_ID $ZOOM $TILE_SIZE $OUTPUT_DIR
}

npgTilesUrl()
{
	if [ $# -ne 4 ]
	then
		echo "Usage $0 image_id x y z"
		return 1
	fi
	local IMAGE_ID=$1
	local TILE_X=$2
	local TILE_Y=$3
	local ZOOM=$4
	
	echo "http://collectionimages.npg.org.uk/zoom/${IMAGE_ID}/zoomXML_files/${ZOOM}/${TILE_X}_${TILE_Y}.jpg"
}

npg()
{
	if [ $# -ne 1 ]
	then
		echo "Usage: $0 image_id"
		return 1
	fi
	local IMAGE_ID="$1"
	local ZOOM=11
	local TILE_SIZE=256
	local OUTPUT_DIR=`makeOutputDir npg`

	local DZI_URL="http://collectionimages.npg.org.uk/zoom/${IMAGE_ID}/zoomXML.dzi"
	local IMG_WIDTH=`curl --silent "$DZI_URL" | sed 's/xmlns=".*"//g' | xmllint --xpath "string(/Image/Size/@Width)" -`
	local IMG_HEIGHT=`curl --silent "$DZI_URL" | sed 's/xmlns=".*"//g' | xmllint --xpath "string(/Image/Size/@Height)" -`

	#overriding global constants
	MIN_FILE_SIZE_BYTES=1
	MAX_TILE_X=`echo "(${IMG_WIDTH} + 128) / 256 - 1" | bc`
	MAX_TILE_Y=`echo "(${IMG_HEIGHT} + 128) / 256 - 1" | bc`

	tiles npgTilesUrl generalTilesFile dullValidate $IMAGE_ID $ZOOM $TILE_SIZE $OUTPUT_DIR
}

if [ $# -lt 2 ]
then
	echo "Usage: $0 grabber <grabber params>"
	exit 1
fi

GRABBER=$1
shift
$GRABBER $@
