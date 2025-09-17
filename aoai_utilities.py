import datetime
from pathlib import Path
import time
import json
import openai
import os
from openai import AzureOpenAI
import requests
import re
import logging
import math
from pydub import AudioSegment
import tempfile
import subprocess

def generate_embeddings(text, model_name=None):
    """
    Generates embeddings for the given text using the specified embeddings model provided by OpenAI.

    Args:
        text (str): The text to generate embeddings for.

    Returns:
        embeddings (list): The embeddings generated for the given text.
    """

    # Configure OpenAI with Azure settings
    openai.api_type = "azure"
    openai.api_base = os.environ['AOAI_ENDPOINT']
    openai.api_version = "2023-03-15-preview"
    openai.api_key = os.environ['AOAI_KEY']

    client = AzureOpenAI(
        azure_endpoint=os.environ['AOAI_ENDPOINT'], api_key=os.environ['AOAI_KEY'], api_version="2023-03-15-preview"
    )

    embedding_model = os.environ['AOAI_EMBEDDINGS_MODEL']
    if model_name is not None:
        embedding_model = model_name

    # Initialize variable to track if the embeddings have been processed
    processed = False
    # Attempt to generate embeddings, retrying on failure
    while not processed:
        try:
            # Make API call to OpenAI to generate embeddings
            response = client.embeddings.create(input=text, model=embedding_model)
            processed = True
        except Exception as e:  # Catch any exceptions and retry after a delay
            logging.error(e)
            print(e)

            # Added to handle exception where passed context exceeds embedding model's context window
            if 'maximum context length' in str(e):
                text = text[:int(len(text)*0.95)]

            time.sleep(5)

    # Extract embeddings from the response
    embeddings = response.data[0].embedding
    return embeddings

def convert_media_to_mp3(filename: str):
    """
    Converts audio/video files to MP3 format for transcription.

    Args:
        filename: Path to the input file

     Returns:
        Path to the MP3 file (either converted or original if not a video)
    """
    file_path = Path(filename)
    media_extensions = [".mp3",".mp4", ".mpeg", ".m4a", ".wav", ".webm"]

    if file_path.suffix.lower() in media_extensions:
        logging.info(
            f"Detected video file ({file_path.suffix}). Converting to MP3 format.")
        out_file, out_path = tempfile.mkstemp(suffix=".mp3")
       
        cmd = [
           "ffmpeg",
            "-i", file_path,
            "-vn",
            "-ac", "1",
            "-ab", "32k",
            "-y",
            out_path
        ]
        subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return out_path
        
        #     # Create a temporary MP3 file for the conversion result
        #     with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp_wav:
        #         mp3_filename = tmp_wav.name
        #     # Ensure ffmpeg is correctly set (update the path as needed)
        #     AudioSegment.converter = r"C:\Program Files\ImageMagick-7.1.1-Q16\ffmpeg.exe"
        #     # Load the video file (pydub will extract the audio track)
        #     audio = AudioSegment.from_file(filename)
        #     # Reduce audio quality to minimize file size
        #     # Convert to mono (1 channel)
        #     audio = audio.set_channels(1)
        #     # Reduce sample rate to 16kHz (sufficient for speech recognition)
        #     audio = audio.set_frame_rate(16000)
        #     # Export with reduced quality settings
        #     audio.export(mp3_filename, format="mp3", bitrate="32k")
        #     logging.info("Conversion to MP3 successful.")
        #     # Return the new WAV file
        #     return mp3_filename
        # except Exception as e:
        #     logging.error(f"Conversion to MP3 failed: {e}")
        #     raise Exception("Conversion to MP3 failed")

    # Return the original filename if not a video file
    return filename


def get_transcription(filename, max_retries=5):
    # Store original filename
    original_filename = filename
    files_to_delete = []

    try:
        # Configure OpenAI with Azure settings
        openai.api_type = "azure"
        openai.api_base = os.environ['AOAI_WHISPER_ENDPOINT']
        openai.api_key = os.environ['AOAI_WHISPER_KEY']
        openai.api_version = "2023-09-01-preview"

        deployment_id = os.environ['AOAI_WHISPER_MODEL']

        transcript = ''

        client = AzureOpenAI(
            api_key=os.environ['AOAI_WHISPER_KEY'],
            azure_endpoint=os.environ['AOAI_WHISPER_ENDPOINT'],
            api_version="2024-02-01"
        )

        # Convert video to MP3
        converted_filename = convert_media_to_mp3(filename)
        if converted_filename != original_filename:
            files_to_delete.append(converted_filename)

        filename = converted_filename

        # Check the file size
        file_size = os.path.getsize(filename)
        max_size = 25 * 1024 * 1024  # 25 MB in bytes

        if file_size > max_size:
            logging.info(
                f"File {filename} is {file_size / (1024 * 1024):.2f} MB, exceeding the 20 MB limit. Splitting into chunks.")

            try:
                AudioSegment.converter = r"C:\Program Files\ImageMagick-7.1.1-Q16\ffmpeg.exe"  # Needed for Windows
                audio = AudioSegment.from_file(filename)
            except Exception as e:
                logging.error(f"Failed to load audio file: {e}")
                raise Exception(f"Failed to load audio file for chunking: {e}")

            # Preserve original file extension for export (will be '.wav' if converted)
            file_extension = os.path.splitext(filename)[1]

            # Calculate number of chunks needed (aiming for ~20MB chunks)
            target_chunk_size = 20 * 1024 * 1024  # 20 MB
            num_chunks = max(1, math.ceil(file_size / target_chunk_size))
            chunk_duration = len(audio) / num_chunks

            logging.info(
                f"Audio duration: {len(audio)/1000:.2f} seconds, splitting into {num_chunks} chunks of {chunk_duration/1000:.2f} seconds each")

            transcript_chunks = []

            for i in range(num_chunks):
                start_time = int(i * chunk_duration)
                end_time = int(min(len(audio), (i + 1) * chunk_duration))

                logging.info(
                    f"Processing chunk {i+1}/{num_chunks}: {start_time/1000:.2f}s to {end_time/1000:.2f}s")

                # Extract the chunk from the audio
                chunk = audio[start_time:end_time]

                # Save the chunk to a temporary file using the original format
                with tempfile.NamedTemporaryFile(suffix=file_extension, delete=False) as temp_file:
                    temp_filename = temp_file.name
                    chunk.export(temp_filename, format="mp3")

                try:
                    chunk_transcribed = False
                    retry_count = 0
                    while not chunk_transcribed and retry_count < max_retries:
                        try:
                            with open(temp_filename, "rb") as audio_file:
                                result = client.audio.transcriptions.create(
                                    file=audio_file,
                                    model=deployment_id
                                )
                            chunk_transcript = result.text
                            chunk_transcribed = True
                            logging.info(
                                f"Successfully transcribed chunk {i+1}/{num_chunks}")
                        except Exception as e:
                            if 'Maximum content size limit' in str(e):
                                raise e
                            retry_count += 1
                            logging.error(
                                f"Error transcribing chunk {i+1}/{num_chunks}: {e} (Attempt {retry_count}/{max_retries})")
                            if retry_count >= max_retries:
                                raise Exception(f"Max retries ({max_retries}) reached while transcribing chunk {i+1}")
                            time.sleep(10)
                    transcript_chunks.append(chunk_transcript)
                finally:
                    # Clean up the temporary chunk file
                    if os.path.exists(temp_filename):
                        try:
                            os.remove(temp_filename)
                        except Exception as e:
                            logging.warning(
                                f"Failed to remove temporary file {temp_filename}: {e}")

            # Combine the transcriptions from each chunk
            transcript = " ".join(transcript_chunks)
            logging.info(
                f"Successfully combined {len(transcript_chunks)} transcript chunks.")
        else:
            transcribed = False
            retry_count = 0
            while not transcribed and retry_count < max_retries:
                try:
                    with open(filename, "rb") as f:
                        result = client.audio.transcriptions.create(
                            file=f, model=deployment_id)
                    transcript = result.text
                    transcribed = True
                except Exception as e:
                    if 'Maximum content size limit' in str(e):
                        raise e
                    retry_count += 1
                    logging.error(f"Error during transcription: {e} (Attempt {retry_count}/{max_retries})")
                    if retry_count >= max_retries:
                        raise Exception(f"Max retries ({max_retries}) reached while transcribing file")
                    time.sleep(10)

        if len(transcript) > 0:
            return transcript

        raise Exception("No transcript generated")

    finally:
        # Clean up files
        files_to_delete.append(original_filename)

        # Using set to avoid duplicates
        for file_to_delete in set(files_to_delete):
            if os.path.exists(file_to_delete):
                try:
                    os.remove(file_to_delete)
                    logging.info(f"Deleted file: {file_to_delete}")
                except Exception as e:
                    logging.warning(
                        f"Failed to delete file {file_to_delete}: {e}")

def classify_image(b64_image_bytes):
    classification_msg = """
    You review images of individual document pages and determine if there is non-textual 
    visual content such as charts, graphs, diagrams, infographics, reference photographs, 
    screenshots, 3D models, or flowcharts.

    Return only TRUE or FALSE for the provided image.
    """

    user_content = {
        "role": "user",
        "content": [
            {
            "type": "image_url",
            "image_url": {
                    "url": f"data:image/jpeg;base64,{b64_image_bytes}"
                     , "detail": "high"
                }
            }  
        ]
    }

    messages = [ 
            { "role": "system", "content": classification_msg }, 
            user_content
    ]

    api_base = os.environ['AOAI_ENDPOINT']
    api_key = os.environ['AOAI_KEY']
    deployment_name = os.environ['AOAI_GPT_VISION_MODEL']

    base_url = f"{api_base}openai/deployments/{deployment_name}" 
    headers = {   
        "Content-Type": "application/json",   
        "api-key": api_key 
    } 
    endpoint = f"{base_url}/chat/completions?api-version=2023-12-01-preview" 
    data = { 
        "messages": messages, 
        "temperature": 0.0,
        "top_p": 0.95,
        "max_tokens": 50
    }   

    # Make the API call   
    processed = False
    out_str = ''

    while not processed:
        try:
            response = requests.post(endpoint, headers=headers, data=json.dumps(data)) 
            if response.status_code == 429:
                time.sleep(5)
                continue 
            resp_str = response.json()['choices'][0]['message']['content']
            out_str = resp_str
            processed = True
        except Exception as e:
            if 'exceeded token rate' in str(e).lower():
                time.sleep(5)
            else:
                processed = True
                
    if 'true' in out_str.lower():
        return True
    else:
        return False
    

def analyze_image(b64_image_bytes):
    classification_msg = """
    You review images of individual document pages and describe non-textual visual content such as charts, 
    graphs, diagrams, infographics, reference photographs, screenshots, 3D models, or flowcharts.

    Your response should be a JSON object describing the essential non-textual visual content on the page. 
    The key should refer to the object and the value should be a detailed description.
    """

    user_content = {
        "role": "user",
        "content": [
            {
            "type": "image_url",
            "image_url": {
                    "url": f"data:image/jpeg;base64,{b64_image_bytes}"
                     , "detail": "high"
                }
            }  
        ]
    }

    messages = [ 
            { "role": "system", "content": classification_msg }, 
            user_content
    ]

    api_base = os.environ['AOAI_ENDPOINT']
    api_key = os.environ['AOAI_KEY']
    deployment_name = os.environ['AOAI_GPT_VISION_MODEL']

    base_url = f"{api_base}openai/deployments/{deployment_name}" 
    headers = {   
        "Content-Type": "application/json",   
        "api-key": api_key 
    } 
    endpoint = f"{base_url}/chat/completions?api-version=2023-12-01-preview" 
    data = { 
        "messages": messages, 
        "temperature": 0.0,
        "top_p": 0.95,
        "max_tokens": 800
    }   

    # Make the API call   
    processed = False
    out_str = ''

    while not processed:
        try:
            response = requests.post(endpoint, headers=headers, data=json.dumps(data)) 
            if response.status_code == 429:
                time.sleep(5)
                continue
            resp_str = response.json()['choices'][0]['message']['content']
            out_str = resp_str
            processed = True
        except Exception as e:
            if 'exceeded token rate' in str(e).lower():
                time.sleep(5)
            else:
                processed = True
                break

    # Regex pattern to match the outer-most JSON object
    pattern = re.compile(r'\{.*\}', re.DOTALL)
    # Search for the JSON object
    match = pattern.search(out_str)

    # Extract and print the JSON object if found
    if match:
        out_str = match.group(0)

    return out_str
        

def generate_qna_pair_helper(content):
    sys_msg = """You are a helpful AI assistant who reviews snippets of documents and generates a question and answer pair that can be UNIQUELY answered by the content within the provided document. 
    The question-answer pair you generate should be specific to the underlying information in the provided documents, rather than a question about the document itself. 
    To the extent possible, these questions should cover broader ideas.
    Ideally, these questions should be answerable without an individual having the document directly in front of them.
    For instance, ask 'What are the emerging trends in AI in 2024?' rather than 'What are the key AI trends listed in the document?' 

    Your output format should be a JSON object with the following structure:

    {
        'question': '',
        'answer':''
    }
    """
    user_msg = f"""Generate a question/answer pair based on the following content.

    ## CONTENT: {content}
    """
    
    messages = [ 
            { "role": "system", "content": sys_msg }, 
            {"role": "user", "content": user_msg}
    ]

    api_base = os.environ['AOAI_ENDPOINT']
    api_key = os.environ['AOAI_KEY']
    deployment_name = os.environ['AOAI_GPT_VISION_MODEL']

    base_url = f"{api_base}openai/deployments/{deployment_name}" 
    headers = {   
        "Content-Type": "application/json",   
        "api-key": api_key 
    } 
    endpoint = f"{base_url}/chat/completions?api-version=2023-12-01-preview" 
    data = { 
        "messages": messages, 
        "temperature": 0.0,
        "top_p": 0.95,
        "max_tokens": 500,
        "response_format": {"type": "json_object"}
    }   

    # Make the API call   
    processed = False
    out_str = ''

    while not processed:
        try:
            response = requests.post(endpoint, headers=headers, data=json.dumps(data)) 
            if response.status_code == 429:
                time.sleep(5)
                continue
            resp_str = response.json()['choices'][0]['message']['content']
            out_str = resp_str
            processed = True
        except Exception as e:
            if 'exceeded token rate' in str(e).lower():
                time.sleep(5)
            else:
                processed = True
                
    return json.loads(out_str)

def generate_summary_template(content, template_generation_prompt, gpt_model='gpt-4.1'):

    messages = [ 
            { "role": "system", "content": template_generation_prompt }, 
            {"role": "user", "content": content}
    ]

    api_base = os.environ['AOAI_ENDPOINT']
    api_key = os.environ['AOAI_KEY']
    deployment_name = gpt_model

    base_url = f"{api_base}openai/deployments/{deployment_name}" 
    headers = {   
        "Content-Type": "application/json",   
        "api-key": api_key 
    } 
    endpoint = f"{base_url}/chat/completions?api-version=2025-04-01-preview" 
    data = { 
        "messages": messages, 
        "temperature": 0.0,
        "max_tokens": 1500,
    }   

    processed = False
    out_str = ''

    while not processed:
        try:
            response = requests.post(endpoint, headers=headers, data=json.dumps(data)) 
            if response.status_code == 429:
                time.sleep(5)
                continue
            resp_str = response.json()['choices'][0]['message']['content']
            out_str = resp_str
            processed = True
        except Exception as e:
            if 'exceeded token rate' in str(e).lower():
                time.sleep(5)
            else:
                processed = True
                
    return (out_str)

def summarize_section(content, template, section_analysis_prompt, gpt_model='gpt-4.1'):
    """
    Summarizes a section of text using the specified GPT model.

    Args:
        content (str): The text to summarize.
        gpt_model (str): The GPT model to use for summarization.

    Returns:
        str: The summary of the text.
    """

    # Define the prompt for summarization
    summary_prompt = f"""{section_analysis_prompt}
    
    ---
    TEMPLATE DESCRIPTION:
    """ + template

    messages = [ 
            { "role": "system", "content": summary_prompt }, 
            {"role": "user", "content": content}
    ]

    api_base = os.environ['AOAI_ENDPOINT']
    api_key = os.environ['AOAI_KEY']
    deployment_name = gpt_model

    base_url = f"{api_base}openai/deployments/{deployment_name}" 
    headers = {   
        "Content-Type": "application/json",   
        "api-key": api_key 
    } 
    endpoint = f"{base_url}/chat/completions?api-version=2025-04-01-preview" 
    data = { 
        "messages": messages, 
        "temperature": 0.0,
        "max_tokens": 8000,
    }   

    processed = False
    out_str = ''

    while not processed:
        try:
            response = requests.post(endpoint, headers=headers, data=json.dumps(data)) 
            if response.status_code == 429:
                time.sleep(5)
                continue
            resp_str = response.json()['choices'][0]['message']['content']
            out_str = resp_str
            processed = True
        except Exception as e:
            if 'exceeded token rate' in str(e).lower():
                time.sleep(5)
            else:
                processed = True
                
    return out_str

def generate_full_summary(template, sections, full_summary_base_prompt, gpt_model='gpt-4.1'):
    """
    Generates a full summary of the document using the provided template and sections.

    Args:
        template (str): The template for the summary.
        sections (list): The sections of the document to summarize.
        gpt_model (str): The GPT model to use for summarization.

    Returns:
        str: The full summary of the document.
    """

    # Define the prompt for generating the full summary
    full_summary_prompt = f"""{full_summary_base_prompt}

    ---
    TEMPLATE DESCRIPTION:
    """ + template

    messages = [ 
            { "role": "system", "content": full_summary_prompt }, 
            {"role": "user", "content": "\n\n".join(sections)}
    ]

    api_base = os.environ['AOAI_ENDPOINT']
    api_key = os.environ['AOAI_KEY']
    deployment_name = gpt_model

    base_url = f"{api_base}openai/deployments/{deployment_name}" 
    headers = {   
        "Content-Type": "application/json",   
        "api-key": api_key 
    } 
    endpoint = f"{base_url}/chat/completions?api-version=2025-04-01-preview" 
    data = { 
        "messages": messages, 
        "temperature": 0.0,
        "max_tokens": 20000,
    }   

    processed = False
    out_str = ''

    while not processed:
        try:
            response = requests.post(endpoint, headers=headers, data=json.dumps(data)) 
            if response.status_code == 429:
                time.sleep(5)
                continue
            resp_str = response.json()['choices'][0]['message']['content']
            out_str = resp_str
            processed = True
        except Exception as e:
            if 'exceeded token rate' in str(e).lower():
                time.sleep(5)
            else:
                processed = True
                
    return out_str