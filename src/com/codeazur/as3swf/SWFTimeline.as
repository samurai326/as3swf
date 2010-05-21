package com.codeazur.as3swf
{
	import com.codeazur.as3swf.data.SWFFrameLabel;
	import com.codeazur.as3swf.data.SWFRecordHeader;
	import com.codeazur.as3swf.data.SWFScene;
	import com.codeazur.as3swf.data.consts.SoundCompression;
	import com.codeazur.as3swf.factories.SWFTagFactory;
	import com.codeazur.as3swf.tags.IDefinitionTag;
	import com.codeazur.as3swf.tags.ITag;
	import com.codeazur.as3swf.tags.TagDefineSceneAndFrameLabelData;
	import com.codeazur.as3swf.tags.TagEnd;
	import com.codeazur.as3swf.tags.TagFrameLabel;
	import com.codeazur.as3swf.tags.TagPlaceObject;
	import com.codeazur.as3swf.tags.TagPlaceObject2;
	import com.codeazur.as3swf.tags.TagPlaceObject3;
	import com.codeazur.as3swf.tags.TagRemoveObject;
	import com.codeazur.as3swf.tags.TagRemoveObject2;
	import com.codeazur.as3swf.tags.TagShowFrame;
	import com.codeazur.as3swf.tags.TagSoundStreamBlock;
	import com.codeazur.as3swf.tags.TagSoundStreamHead;
	import com.codeazur.as3swf.tags.TagSoundStreamHead2;
	import com.codeazur.as3swf.timeline.Frame;
	import com.codeazur.as3swf.timeline.FrameObject;
	import com.codeazur.as3swf.timeline.LayerObject;
	import com.codeazur.as3swf.timeline.Scene;
	import com.codeazur.as3swf.timeline.SoundStream;
	import com.codeazur.utils.StringUtils;
	
	import flash.utils.ByteArray;
	import flash.utils.Dictionary;
	import flash.utils.Endian;

	public class SWFTimeline
	{
		public var parent:ITimeline;
		
		protected var _tags:Vector.<ITag>;
		protected var _dictionary:Dictionary;
		protected var _scenes:Vector.<Scene>;
		protected var _frames:Vector.<Frame>;
		protected var _layers:Vector.<Array>;
		protected var _soundStream:SoundStream;

		protected var currentFrame:Frame;
		protected var frameLabels:Dictionary;
		protected var hasSoundStream:Boolean = false;
		
		public function SWFTimeline(parent:ITimeline)
		{
			this.parent = parent;
			
			_tags = new Vector.<ITag>();
			_dictionary = new Dictionary();
			_scenes = new Vector.<Scene>();
			_frames = new Vector.<Frame>();
			_layers = new Vector.<Array>();
		}
		
		public function get tags():Vector.<ITag> { return _tags; }
		public function get dictionary():Dictionary { return _dictionary; }
		public function get scenes():Vector.<Scene> { return _scenes; }
		public function get frames():Vector.<Frame> { return _frames; }
		public function get layers():Vector.<Array> { return _layers; }
		public function get soundStream():SoundStream { return _soundStream; }
		
		public function getTagByCharacterId(characterId:uint):ITag {
			return tags[dictionary[characterId]];
		}
		
		public function parse(data:SWFData, version:uint):void
		{
			tags.length = 0;
			frames.length = 0;
			layers.length = 0;
			_dictionary = new Dictionary();
			
			currentFrame = new Frame();
			frameLabels = new Dictionary();
			hasSoundStream = false;
			
			var raw:ByteArray;
			var header:SWFRecordHeader;
			var tag:ITag;
			var pos:uint;
			
			while (!header || header.type != TagEnd.TYPE)
			{
				pos = data.position;
				// Bail out if eof
				if(pos > data.length) {
					trace("WARNING: end of file encountered, no end tag.");
					break;
				}
				header = data.readTagHeader();
				tag = SWFTagFactory.create(header.type);
				tag.parent = this;
				tag.rawIndex = pos;
				tag.rawLength = header.tagLength;
				try {
					tag.parse(data, header.contentLength, version);
				} catch(e:Error) {
					// If we get here there was a problem parsing this particular tag.
					// Corrupted SWF, possible SWF exploit, or obfuscated SWF.
					// TODO: register errors and warnings
					trace("WARNING: parse error: " + e.message + ", Tag: " + tag.name + ", Index: " + tags.length);
				}
				// Register parsed tag, build dictionary and display list etc
				processTag(tag);
				// Adjust position (just in case the parser under- or overflows)
				if(data.position != pos + header.tagLength) {
					trace("WARNING: excess bytes: " + 
						(data.position - (pos + header.tagLength)) + ", " +
						"Tag: " + tag.name + ", " +
						"Index: " + (tags.length - 1)
					);
					data.position = pos + header.tagLength;
				}
			}
			
			if(soundStream && soundStream.data.length == 0) {
				_soundStream = null;
			}
			
			buildLayers();
		}
		
		public function publish(data:SWFData, version:uint):void
		{
			for (var i:uint = 0; i < tags.length; i++)
			{
				try {
					tags[i].publish(data, version);
				}
				catch (e:Error) {
					var tag:ITag = tags[i];
					trace("WARNING: publish error: " + e.message + " (tag: " + tag.name + ", index: " + i + ")");
					if (tag.rawLength > 0) {
						data.writeBytes(tag.raw);
					} else {
						throw(e);
					}
				}
			}
		}
		
		protected function processTag(tag:ITag):void {
			var currentTagIndex:uint = tags.length;
			// Register tag
			tags.push(tag);
			// Register definition tag in dictionary (key: character id, value: tag index)
			if(tag is IDefinitionTag) {
				var definitionTag:IDefinitionTag = tag as IDefinitionTag;
				if(definitionTag.characterId > 0) {
					dictionary[definitionTag.characterId] = currentTagIndex;
					currentFrame.characters.push(definitionTag.characterId);
				}
			}
			switch(tag.type)
			{
				// Register display list tags
				case TagShowFrame.TYPE:
					currentFrame.tagIndexEnd = currentTagIndex;
					if(currentFrame.label == null && frameLabels[currentFrame.frameNumber]) {
						currentFrame.label = frameLabels[currentFrame.frameNumber];
					}
					frames.push(currentFrame);
					currentFrame = currentFrame.clone();
					currentFrame.frameNumber = frames.length;
					currentFrame.tagIndexStart = currentTagIndex + 1; 
					break;
				case TagPlaceObject.TYPE:
				case TagPlaceObject2.TYPE:
				case TagPlaceObject3.TYPE:
					var tagPlaceObject:TagPlaceObject = tag as TagPlaceObject;
					currentFrame.placeObject(currentTagIndex, tagPlaceObject.depth, tagPlaceObject.characterId);
					break;
				case TagRemoveObject.TYPE:
				case TagRemoveObject2.TYPE:
					var tagRemoveObject:TagRemoveObject = tag as TagRemoveObject;
					currentFrame.removeObject(tagRemoveObject.depth, tagRemoveObject.characterId);
					break;

				// Register frame labels and scenes
				case TagDefineSceneAndFrameLabelData.TYPE:
					var tagSceneAndFrameLabelData:TagDefineSceneAndFrameLabelData = tag as TagDefineSceneAndFrameLabelData;
					var i:uint;
					for(i = 0; i < tagSceneAndFrameLabelData.frameLabels.length; i++) {
						var frameLabel:SWFFrameLabel = tagSceneAndFrameLabelData.frameLabels[i] as SWFFrameLabel;
						frameLabels[frameLabel.frameNumber] = frameLabel.name;
					}
					for(i = 0; i < tagSceneAndFrameLabelData.scenes.length; i++) {
						var scene:SWFScene = tagSceneAndFrameLabelData.scenes[i] as SWFScene;
						scenes.push(new Scene(scene.offset, scene.name));
					}
					break;
				case TagFrameLabel.TYPE:
					var tagFrameLabel:TagFrameLabel = tag as TagFrameLabel;
					currentFrame.label = tagFrameLabel.frameName;
					break;

				// Register sound stream
				case TagSoundStreamHead.TYPE:
				case TagSoundStreamHead2.TYPE:
					var tagSoundStreamHead:TagSoundStreamHead = tag as TagSoundStreamHead;
					_soundStream = new SoundStream();
					soundStream.compression = tagSoundStreamHead.streamSoundCompression;
					soundStream.rate = tagSoundStreamHead.streamSoundRate;
					soundStream.size = tagSoundStreamHead.streamSoundSize;
					soundStream.type = tagSoundStreamHead.streamSoundType;
					soundStream.numFrames = 0;
					soundStream.numSamples = 0;
					break;
				case TagSoundStreamBlock.TYPE:
					if(soundStream != null) {
						if(!hasSoundStream) {
							hasSoundStream = true;
							soundStream.startFrame = currentFrame.frameNumber;
						}
						var tagSoundStreamBlock:TagSoundStreamBlock = tag as TagSoundStreamBlock;
						var soundData:ByteArray = tagSoundStreamBlock.soundData;
						soundData.endian = Endian.LITTLE_ENDIAN;
						soundData.position = 0;
						switch(soundStream.compression) {
							case SoundCompression.ADPCM: // ADPCM
								// TODO
								break;
							case SoundCompression.MP3: // MP3
								var numSamples:uint = soundData.readUnsignedShort();
								var seekSamples:int = soundData.readShort();
								if(numSamples > 0) {
									soundStream.numSamples += numSamples;
									soundStream.data.writeBytes(soundData, 4);
								}
								break;
						}
						soundStream.numFrames++;
					}
					break;
			}
		}
		
		protected function buildLayers():void {
			var i:uint;
			var depth:String;
			var depthInt:uint;
			var depths:Dictionary = new Dictionary();
			var depthsAvailable:Array = [];
			for(i = 0; i < frames.length; i++) {
				var frame:Frame = frames[i];
				for(depth in frame.objects) {
					depthInt = parseInt(depth);
					var layerObject:LayerObject = new LayerObject(frame.frameNumber, depthInt);
					if(depthsAvailable.indexOf(depthInt) > -1) {
						(depths[depth] as Array).push(layerObject);
					} else {
						depths[depth] = [layerObject];
						depthsAvailable.push(depthInt);
					}
				}
			}
			depthsAvailable.sort(Array.NUMERIC);
			for(i = 0; i < depthsAvailable.length; i++) {
				_layers.push(depths[depthsAvailable[i]]);
			}
			for(i = 0; i < frames.length; i++) {
				var frameObjs:Dictionary = frames[i].objects;
				for(depth in frameObjs) {
					FrameObject(frameObjs[depth]).layer = depthsAvailable.indexOf(parseInt(depth));
				}
			}	
		}
		
		public function toString(indent:uint = 0):String {
			var i:uint;
			var str:String = "";
			if (tags.length > 0) {
				str += "\n" + StringUtils.repeat(indent + 2) + "Tags:";
				for (i = 0; i < tags.length; i++) {
					str += "\n" + tags[i].toString(indent + 4);
				}
			}
			if (scenes.length > 0) {
				str += "\n" + StringUtils.repeat(indent + 2) + "Scenes:";
				for (i = 0; i < scenes.length; i++) {
					str += "\n" + scenes[i].toString(indent + 4);
				}
			}
			if (frames.length > 0) {
				str += "\n" + StringUtils.repeat(indent + 2) + "Frames:";
				for (i = 0; i < frames.length; i++) {
					str += "\n" + frames[i].toString(indent + 4);
				}
			}
			if (layers.length > 0) {
				str += "\n" + StringUtils.repeat(indent + 2) + "Layers:";
				for (i = 0; i < layers.length; i++) {
					str += "\n" + StringUtils.repeat(indent + 4) +
						"[" + i + "] Frames " +
						layers[i].join(", ");
				}
			}
			return str;
		}
	}
}
